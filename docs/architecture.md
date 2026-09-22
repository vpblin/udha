# Architecture

A maintainer's reference for Udha: what the pieces are, how they fit, and the handful of details that are
load-bearing rather than tidy. If you are about to change anything under `Sessions/`, `Bridge/` or `Config/`,
read the sections on classification, the Linux port and the conventions first — those are the places where an
obvious-looking simplification has already been tried and has already broken something.

- [Processes and shape](#processes-and-shape)
- [Repository layout](#repository-layout)
- [Design system](#design-system)
- [The main window](#the-main-window)
- [Sessions](#sessions)
- [Classification](#classification)
- [Status model](#status-model)
- [Attention inbox](#attention-inbox)
- [Claude login pools](#claude-login-pools)
- [Embedded terminal](#embedded-terminal)
- [Agents](#agents)
- [Meetings](#meetings)
- [Recordings](#recordings)
- [Machines and system stats](#machines-and-system-stats)
- [Overlay](#overlay)
- [Audio capture](#audio-capture)
- [Slack and the inbox](#slack-and-the-inbox)
- [Bridge, remote hosts and udha-agent](#bridge-remote-hosts-and-udha-agent)
- [Input lock](#input-lock)
- [Config and secrets](#config-and-secrets)
- [Conventions](#conventions)
- [Headless verification](#headless-verification)

---

## Processes and shape

Udha is three programs that share one body of code.

| | |
| --- | --- |
| **The Mac app** (`Udha.AIDesktop/`) | SwiftUI + AppKit. Owns the window, the overlay, meetings, recordings, and the sessions running on this Mac. |
| **`udha-agent`** (`udha-agent/`) | The same session engine and the same wire protocol, compiled for Linux as a SwiftPM executable and run as a `systemd --user` service. No UI. |
| **The relay** (`relay/`) | A small WebSocket server that introduces a client (Mac app, phone app) to a host (Mac app, agent) over the open internet. Stateless about sessions; it only routes. |

A session is **owned by exactly one supervisor** — the machine it runs on. Everything else is a view. The Mac app
supervises its own sessions and is simultaneously a *client* of every agent it is paired with, so both machines'
sessions land in one `SessionStateStore` and every list, count and hotkey addresses them uniformly.

## Repository layout

```
Udha.AIDesktop.xcodeproj       single scheme: Udha.AIDesktop
run.sh                         resilient launcher (build → verify → launch)
Udha.xcconfig                  bundle id + team, overridable by Local.xcconfig (git-ignored)
scripts/make-app-icon.swift    regenerates every AppIcon slot from CoreGraphics
tests/                         Swift round-trip tests + the attention MCP protocol test
relay/                         self-hostable WebSocket relay (see relay/README.md)
udha-agent/                    headless Linux build — Sources/udha-agent/Shared/* are symlinks
docs/                          this file, the self-hosting guide, design notes

Udha.AIDesktop/
  Udha_AIDesktopApp.swift      @main; one Window + one MenuBarExtra
  App/                         AppCore (lifetime-scoped state), AppDelegate
  DesignSystem/                UdhaTheme (tokens) + UdhaControls (primitives)
  Shell/                       the window: sidebar, board, panes, palette, settings
  Overlay/                     the right-edge hover UI + the lock chip and curtain
  Sessions/                    tmux glue, state store, pane reader, hook sidecar,
                               attention agent, embedded terminal, stats collector
  Agents/                      reusable .md prompts + library store
  Meetings/                    capture, chunking, STT, notes, swimlane, calendar
  Recordings/                  screen + camera capture, captions, compositor, publisher
  Machines/                    fleet monitor, history ring, tailnet, per-machine summary
  Slack/                       poller, API client, per-thread inbox store
  Bridge/                      the *host* half of the relay protocol + Auth0
  RemoteHost/                  the *client* half: drive another machine's sessions
  Voice/                       Core Audio microphone capture, playback, device list
  Activity/                    append-only in-memory event log
  Security/ Hotkey/            input lock: event tap, hotkeys
  Config/                      AppConfig + tolerant JSON store + Keychain
  Menu/ Onboarding/ Shared/    menu bar, first run, logger and small utilities
```

New SwiftUI views go in the relevant subsystem folder; the target uses a file-system synchronized group, so they
are picked up without touching the project file.

## Design system

`DesignSystem/` is the macOS HIG idiom: the system font, a unified 52pt toolbar as the title bar, vibrancy under
the sidebar and list column, cards with a soft shadow on a flat canvas, 6–12pt corners, one tinted accent for
selection and primary actions, and green / amber / red for good / warn / bad.

- **`UdhaTheme`.** Every colour is adaptive — `adaptive(light, dark)` builds an `NSColor` with a dynamic provider
  — so one token is correct in both appearances. Surfaces `canvas`, `card`, `chrome`, `sidebar`, `list`, `fill`,
  `fillStrong`, `sel`; text `label`, `secondary`, `tertiary`, `inkCode`; lines `separator` and `hairline` (both
  0.5pt); accent `accent`, `accentTint`, `accentInk`, `onAccent`, read from the `accentChoice` setting; semantic
  `good`/`warn`/`bad` with `…Tint` and `…Ink`. An older vocabulary (`paper`, `ink`, `red`, `muted`, …) survives
  as computed aliases so untouched views re-theme; new code uses the new names.
- **Appearance is a setting** (`config.appearance`: mode, accent, ambient glow, hover motion).
  `UdhaTheme.apply(config:)` sets `NSApp.appearance` and bumps a revision that `UdhaRootView` re-keys on, so the
  accent is re-read everywhere at once.
- **`UdhaControls`** holds the primitives: button styles, `.udhaCard()`, `.udhaWell()`, `.udhaChrome(material:)`,
  chips, pills, meters, switches, segmented controls, fields, `Sparkline`, `AmbientGlow`, and the state atoms
  (`StateMark`, `PingDot`, `WorkingDots`, `WaveBars`).

Two rules with teeth:

- **Never `ignoresSafeArea` on `.udhaChrome`.** A view touching the toolbar region grows into it and paints over
  the traffic lights.
- **Hover state lives in a nested `View` inside a `ButtonStyle`, never in the style struct.** `makeBody` is not a
  View body, so `@State` on a `ButtonStyle` has no identity to attach to and silently does nothing.

Animated atoms use `TimelineView`, never a `Timer`, so a card scrolled out of a lazy list leaves nothing ticking.

## The main window

`UdhaRootView` is a native unified toolbar (so the traffic lights are centred and the bar drags the window), a
sidebar + content split, and a 28pt status bar. The command palette and Settings are overlays on top, not scenes:
there is no SwiftUI `Settings` scene — ⌘, and the app menu both post `.udhaRequestSettings`.

- `UdhaShellModel` (`@Observable`) holds every piece of *view* state — active section, selection, palette and
  settings query and cursor, the status line. Deliberately not in `AppCore`, which owns things that outlive the
  window.
- `UdhaSidebar` is two columns over vibrancy: a 194pt nav sidebar and a 320pt list column for the active section.
- `SessionsBoard` groups sessions by machine, one column each, with folder rows first and loose cards after.
  Cards are **not** bucketed by attention state: an assistant changes phase every few seconds, and a card that
  jumps to a different part of the column on each change is unpointable. State is carried by the card's own mark,
  colour and status line; attention still drives the header counts and the card accent.
- `UdhaCommandPalette` (⌘K) rebuilds its registry from live state on every keystroke, so each row's hint names
  the thing it will act on. Commands that cannot run **stay listed and say why** rather than disappearing.
- `UdhaSettingsSheet` searches globally: typing "mic" surfaces the microphone rows from Meetings and
  *Keys & devices* together, each stamped with its section. The section rail is Overview, Appearance, Sessions,
  Claude logins, Edge overlay, Meetings, Slack, Focus & lock, Keys & devices, iPhone, Advanced.

Cross-window messages are `Notification.Name`s (`.udhaRequestNewSession`, `.udhaRequestSettings`,
`.udhaRequestMeetings`, `.udhaFocusSession`, `.udhaOverlayConfigChanged`). The main window is never disposed
while the app lives; activation policy is `.regular` and the app keeps running after the last window closes.

## Sessions

Each `SessionConfig` (label, directory, command, args, priority) is spawned by `SessionManager.spawn` into a tmux
session named `udha-{label}-{shortid}`.

- Output is piped to `/tmp/udha/{tmuxName}.log` with `tmux pipe-pane`; `TmuxSession` streams it with a `tail -F`
  subprocess into a 2000-line `RingBuffer` (ANSI stripped).
- `tmux capture-pane` polls every 2s for a visible-pane snapshot — the only thing that works for a TUI that
  redraws instead of emitting lines. `tmux has-session` polls every 1s to detect exits and propagate exit codes.
- `SessionStateStore` holds `SessionSnapshot` values plus an ordered id list, and publishes `focusedSessionID`.
  `visible` is what every list and count reads; `all` is for plumbing that must still see a hidden session.
- Terminal windows are reclaimed at launch by matching `tmux list-clients -F "#{client_tty}"` against
  Terminal.app's `tty of tab`, so a relaunch does not duplicate windows.

**Which assistant** a session runs is `SessionTool` (`claude` | `codex` | `qwen`), *derived from the command*
rather than stored beside it. The stored value stays the raw binary, so every session already on disk keeps
working and a hand-typed command (`npm run dev`) simply has no tool. The posture dropdown swaps with the choice
(`ClaudePermissionMode` / `CodexApprovalMode` / `QwenApprovalMode`, four matching rungs each).

`SessionTool.isLocal` marks Qwen: pointed at an Ollama server, the model answering is on hardware you own, costs
nothing and reports no spend because there is none. The approval picker is the only thing between it and the
disk — there is no vendor-side refusal behind it.

**Folders and hidden** are owned by the machine that supervises the session, exactly like its label and its place
in the list. `SessionFolder` lives in that machine's `AppConfig.sessionFolders`; membership is
`SessionConfig.folderID`, hiding is `SessionConfig.hidden`. Every edit funnels through `SessionManager`
(`setFolder`, `setHidden`, `createFolder`, `renameFolder`, `deleteFolder`, `setFolderHidden`, `unhideAll`), which
forwards a remote row to its host and **never touches the store for it** — the host's delta or full push is the
echo. Two things are client-side view state only: which folders are collapsed, and the search (which overrides
collapse).

> `SessionConfig.hidden` is `Bool?`, not `Bool = false`. Synthesized `Decodable` throws on a missing key
> regardless of the default, and `ConfigStore`'s tolerant merge cannot fill defaults *inside* the `sessions`
> array — a non-optional key would fail to decode every pre-existing entry and reset the whole config. Any new
> per-session field has to be optional for the same reason.

**Attachments.** Dropping an image on the session pane copies it into `/tmp/udha/attachments` and puts its path
at the head of the next message: a tmux pane cannot be handed bytes, so a path the assistant reads is the trick.
A session on another machine gets its own copy over `scp` first, and Send stays disabled until that copy lands.

## Classification

Three sources, in precedence order. All rule-based. **Do not add an LLM here.**

### 1. `ClaudeStatusSidecar` — hooks + statusLine

Claude is spawned with `--settings <generated udha.json>` and `UDHA_SESSION_ID` / `UDHA_STATUS_DIR` in its
environment. Two generated `sh` scripts append hook payloads to `/tmp/udha/status/<uuid>.jsonl` and overwrite
`<uuid>.status.json` with the statusLine payload; `TmuxSession` follows the first with `tail -F` and the second
is read on demand. This yields exact tool names (`PreToolUse.tool_input`), unambiguous turn ends (`Stop`),
permission prompts (`Notification`), real context-window usage and real spend.

- **Hook command paths must be shell-quoted in the settings JSON.** The install directory can contain a space;
  unquoted, every hook dies with `/bin/sh: …/Application: No such file` and the feed is silently empty.
- Only sessions launched with the flag emit. A reattached session keeps an existing feed if one is already on
  disk, so restarting Udha does not orphan a live session's reporting.
- Hooks and statusLine are both skipped until Claude's workspace-trust prompt has been accepted.
- The feed is replayed from the top on restart (`tail -F -n +1`), so phases walk through history in a few
  milliseconds before settling. Harmless, but subagent counts can be briefly wrong until the next `Stop`.

### 2. `ClaudePaneReader` — the rendered pane

Parses `tmux capture-pane -pe`, anchoring on the footer line and reading relative to it: `esc to interrupt` →
streaming, `⏸ plan mode on` → planning, spinner shape → thinking vs finished, `⏺ Tool(args)` → current tool,
`◯ …` → subagents.

- **The footer anchor is the whole edifice.** It matches `shift+tab to cycle`, `? for shortcuts`, `esc to
  interrupt`, the permission-mode row, and `← for agents`. A session in default *ask* mode paints only the
  second; recent Claude Code versions drop `(shift+tab to cycle)` entirely once a session has background shells,
  painting something like `⏵⏵ bypass permissions on · 13 shells, 1 monitor · ← for agents` instead. When the
  anchor stops matching, the reader sees no chrome at all and every session reads as *Starting* — so the anchor
  list is the first thing to check whenever a Claude Code update appears to have broken status.
- **`-e` (escapes kept) is required.** Claude renders ghost next-prompt suggestions in ANSI dim and text you
  actually typed in bright white; the escapes are the only way to tell them apart. The input box is located by
  the rules bracketing it, never by "the last `❯`".
- **Full-pane overlays hold the phase.** `/btw`, the transcript scroller and the fork picker replace the footer
  entirely. That is detected as `isObscured` and the previous phase is *held*, because inferring "not streaming"
  from a covered pane latches a false turn end.
- A turn end is latched from the streaming→quiet edge across two consecutive polls (~4s), never from the spinner
  line, which scrolls away.

### 2b. Codex and Qwen panes

`OutputClassifier.classifyCodexPane` was written against captured frames of a real Codex session driven through a
turn, a sandbox approval and a question:

- `• Working (7s • esc to interrupt)` immediately above the prompt is the only in-flight signal; the
  `• Running x` / `• Ran x` line above it becomes the activity string.
- A numbered `› 1.` choice under a `Press enter to confirm or esc to cancel` / `Press enter to continue` footer
  is a dialog. This covers the command approval **and the update banner and directory-trust prompt a fresh Codex
  opens on**, which is why an unhandled Codex session used to sit on *Starting* until a human looked at it.
- `• Queued follow-up inputs · ? 1 question · shift + ↵ to answer` is a question queued for you (`needsInput`).
- A turn whose last `• …` line ends in `?` is `.idle` carrying that question as `ClassifierResult.question`, so
  the card says what it wants.
- Codex repaints without the Working row for a frame between text and the next tool; the 1.5s stability filter in
  `runClassifier` absorbs that.

**`SessionManager.usesForeignTUI` keeps `ClaudePaneReader` off Codex and Qwen panes, and that gate is
load-bearing for Qwen specifically.** Qwen Code paints `shift + tab to cycle` — one of the footer markers the
Claude reader anchors on — so without the gate the reader identifies a Qwen pane as Claude's and then reads it
with Claude's vocabulary. Qwen says `esc to cancel` where Claude says `esc to interrupt`, so `isStreaming` never
fires: every working session reads as a turn that just ended, and the card says *Ready* while the model is
still typing. **Any assistant added later needs the same gate.**

### 3. `OutputClassifier` — the original regex pass

Now only for plain shell commands: y/n prompts → `needsInput`, `Error:` / `Traceback` → `errored`, and so on,
behind the same ≥1.5s stability filter. `notifications.destructiveKeywords` still flags a pending prompt as
destructive; the session pane draws a warning above the approve buttons when it does.

### Why the `pipe-pane` log is not classified for Claude sessions

It is a redraw torrent. ANSI-stripped it reads like `✻thinking with xhigh effort✢a72577…`; the footer never
survives in it, and it also captures the user's own shell commands. The idle-veto can therefore never match on
that path, so any prompt-shaped text scrolling past flipped the session to `needsInput` — the cause of a
long-standing `needsInput ⇄ working` flap. The log is kept for the output ring and the overlay's activity meter,
and that is all.

## Status model

`SessionState` (`idle`, `working`, `needsInput`, `errored`, `completed`, `crashed`, `starting`, `exited`) drives
the menu bar, the attention flow and the bridge. A parallel `SessionPhase` (`thinking`, `planning`, `usingTool`,
`awaitingApproval`, `awaitingReply`, `idle`, …) carries the fine-grained status and is read only by the UI, via
the shared `SessionSnapshot.statusPresentation(staleAfter:)`.

The distinction that matters is `.idle` (nothing happening) versus `.awaitingReply` (turn ended, waiting on you)
— both used to render as a flat "Idle". `awaitingReply` past `config.staleAfterSeconds` renders "Stale" instead
of "Ready"; **staleness is derived, not a case**.

`costCents` is stored quantized: `SessionStateStore.update` de-dupes by equality, and a raw float would
invalidate every observer on every statusLine tick.

```
spawn → .starting → .idle ⇄ .working ⇄ .needsInput
                              ↘
                                .errored / .crashed / .completed / .exited
```

`scripts/verify-status.py` mirrors the pane reader so the app's view can be diffed against an independent reading
of the same panes.

## Attention inbox

Sessions surface explicit attention events instead of promoting whatever question the parser found last. Events
can be opened, dismissed, snoozed for 15 minutes, or resolved; the inbox is shared by the desktop, the phone and
the headless host. Decisions, approvals and blockers notify by default; reviews and completions are quiet unless
you enable them or arm the bell on a session ("notify when done", satisfied only by an explicit completion report
or a clean process exit — never by a quiet terminal).

`AttentionAgent` installs a **session-scoped stdio MCP server** (`udha_attention`) alongside the status sidecar
for new Claude and Codex sessions: `request_attention(kind, summary, detail?, url?)`,
`resolve_attention(eventID)` and `task_completed(summary, url?)`. It needs `python3` on the login PATH, respects
the assistant's own MCP approval policy, changes no global assistant settings, and — importantly — **adds no LLM
dependency**: it is a mailbox, not a model.

Each host owns its inbox at `Udha.AI/hooks/attention/inbox.json` under Application Support (the Foundation
equivalent on Linux). Session rows carry `attentionState`, the capability is advertised as `attention_events`,
and `attention_action` applies dismiss / snooze / resolve / watch on the owning host. Commands are queued in a
per-session mailbox and acknowledged only after they are persisted; command ids and same-turn summaries de-dupe
retries. Parsed prose never generates a push.

## Claude login pools

A directory tree can have several Claude logins, and a session moves between them when the one it is on hits its
usage limit — so a long run keeps going with nobody at a keyboard.

- **Config.** `ClaudeAccount.alternates: [String]?` names further config directories signed in to other logins
  for the same `pathPrefix`; `pool` is `[configDir] + alternates`. `AppConfig.accountFailover` carries `enabled`,
  `startOnLeastUsed`, `usageProbeIntervalSeconds` and `continuationPrompt`. `SessionConfig.account` remembers the
  directory a session was last launched under. All config-file only.
- **Choosing.** `SessionManager.chooseLogin` at spawn: a reattach stays on whatever the live process has; a fresh
  session starts on the pool member with the most headroom (lowest known utilisation, unknown ranks as 25%,
  limited ones skipped, primary wins ties). Readings come from the documented `rate_limits` block in the
  statusLine payload (five-hour and seven-day `used_percentage` + `resets_at`) and from `ClaudeUsageProbe`, which
  calls the same undocumented OAuth usage endpoint `/usage` uses, authenticated with the access token already in
  `<dir>/.credentials.json`. **That token is never refreshed by us** — refreshing behind a running Claude would
  sign it out; an expired token simply means "unknown".
- **Detecting the hit.** No hook fires when a limit is reached (only one when it *resets*), and the transcript
  gets nothing but an informational line. The pane is the single live signal: the reader matches the
  "Usage limit reached · continuing automatically at …" notice in the lines above the footer as
  `PaneReading.usageLimit`, with the clock. It is checked *before* the sidecar takes over the phase, because the
  sidecar never sees it. This depends on Claude's own auto-continue being left on — it is also the fallback when
  every login in the pool is spent. A same-text notice within 10 minutes, or anything in the 60s after a
  rotation, is ignored.
- **The move.** `SessionManager.rotateAccount` marks the login being left as limited until the clock Claude
  printed (or +5h), picks the next one, and swaps the process **in its own pane** with `tmux respawn-pane -k`.
  That is the point of the design: the tmux session, its attached clients, `pipe-pane` and the sidecar follower
  all survive, so the session keeps its identity everywhere. The new process is launched with the other
  `CLAUDE_CONFIG_DIR` and `--resume <absolute transcript path>` — `--resume` takes a path and reads it from any
  config directory, so the transcript stays where it is and is appended in place. Once the prompt is back,
  `continuationPrompt` is pasted in.
- **What you see.** The session pane carries a login strip: the email the directory is signed in as (read from
  its `.claude.json`), a meter per limit window, and a Switch menu listing every login in the pool with its
  headroom. Every login directory is probed whether pooled or not. A remote session shows the *box's* numbers,
  fetched over the bridge (`fetch_accounts` → `accounts`) on connect and pushed after every probe or move.
  Settings → Claude logins edits the pools of this Mac and of the connected box.

`udha-agent/scripts/add-claude-login.sh <base dir> <suffix> [email]` provisions an additional login directory on
a box: `projects`, `settings.json`, `skills`, `plugins`, `agents`, `commands`, `CLAUDE.md` and `history.jsonl`
are **symlinked** back to the base (one shared `projects/` = one memory store and one transcript store), a
`.claude.json` is seeded from the base's trust flags minus the account block, `claude auth login` runs
interactively, and the new directory is appended to the base's `alternates`.

> Each login directory must be a seat that is yours to use. Provider plan terms generally make limits per-member
> and forbid sharing a login; the pool assumes you are pooling *your own* seats.

## Embedded terminal

A live terminal for the selected session, inside Udha's window. Off by default (`config.embeddedTerminal`).

**Why an emulator and not a real terminal app.** macOS cannot host another application's window inside yours —
there is no native iframe — so "embed iTerm2" is not an option that exists. Every editor with an integrated
terminal runs its own emulator (VS Code and Cursor over xterm.js, Zed over `alacritty_terminal`, CodeEdit over
SwiftTerm). This is the same move, pointed at the tmux session Udha already owns. `SwiftTerm` is imported **in
`Sessions/EmbeddedTerminal.swift` and nowhere else**, and the rest of the app only ever sees
`EmbeddedTerminalController`, so swapping the emulator (libghostty, when its API stabilizes) is a rewrite of that
one file.

- It is only ever a **second tmux client**. Closing the pane, switching the feature off or quitting detaches and
  leaves the work running, and a real terminal can be attached at the same time.
- Attach line: `tmux set -g window-size latest; exec tmux -u attach -t <name>`, wrapped in `ssh -t <host> …` for
  a remote session. **`window-size latest` is load-bearing**: tmux otherwise sizes a window to its *smallest*
  client, so opening this pane beside an attached terminal window wraps the assistant's output in both.
- **The bug that makes a hosted terminal look broken.** SwiftTerm's `mouseDown` forwards the click to the remote
  app and **returns before taking first responder** whenever mouse reporting is on — which tmux and Claude both
  turn on. The terminal then renders live and never receives a keystroke: arrows do not move a model picker,
  Enter does nothing. `UdhaTerminalView` overrides `mouseDown` to take focus first, and the surface also grabs
  first responder when the tab opens.
- **The second bug that makes a hosted terminal look broken.** macOS dictation previews its hypothesis as marked
  text and then commits the sentence through `insertText` as an **`NSAttributedString`**. SwiftTerm only unwraps
  `string as? NSString`, so the commit matches nothing and the words vanish the instant the overlay disappears —
  indistinguishable from "dictation does not work in this app". `UdhaTerminalView.insertText` flattens attributed
  input before calling super.
- Selection follows the terminal-with-tmux convention: a plain drag is forwarded to tmux, ⇧-drag selects. ⌘C/⌘V
  work, and OSC 52 from a remote box lands on the Mac clipboard.
- `EmbeddedTerminalStore` caches one controller per session, capped at **4 attached** (LRU): browsing fifteen
  session cards would otherwise leave fifteen tmux clients, each remote one its own SSH connection. Controllers
  are pruned when a session disappears, and all are closed on shutdown or when the setting is switched off.
- The palette is handed over as **static sRGB colours, never the theme's dynamic `NSColor`s.** SwiftTerm keeps
  what it is given, and the Metal pass re-resolves it every frame off AppKit's drawing path, where a dynamic
  colour follows the *system* appearance — a light Mac with a dark Udha painted a white terminal with black text
  inside a dark window.
- The store replaces a cached controller when a session's tmux name changes (renaming a session renames the tmux
  session too); reattaching with the old name reports "can't find session" for a session that is alive.
- Still missing versus a real terminal: no splits or tabs of its own (tmux does that), no ⌘F find bar, no ⌘+/⌘−.

## Agents

An **agent** is a reusable named prompt: a plain `.md` file with `name` / `description` / `icon` frontmatter above
the prompt body. `Agent.parse` / `serialized` handle the round trip, and the filename slug is the stable id.
`AgentStore` reads and writes `~/Library/Application Support/Udha.AI/Agents/*.md`; built-ins ship as bundled
resources and are copied in on launch when missing, so a deleted built-in comes back and user agents are never
touched.

`SessionManager.runAgent` spawns a fresh session in the chosen folder, tags it with the agent's name, and after a
short boot delay injects the prompt with `TmuxSession.sendPrompt` — `load-buffer` + `paste-buffer -p`, i.e.
bracketed paste, so a multi-line prompt is not submitted line by line, followed by Enter.

## Meetings

Two capture streams: the microphone ("Me") and everything the Mac plays ("Them", a Core Audio process tap and a
private aggregate device, with Udha's own process excluded so nothing the app itself plays lands in the
transcript). Because
they are separate streams, **no diarization is needed**.

Both are converted to PCM16 mono 16k and cut into 15–45s chunks on silence boundaries by `AudioChunker`, which
uses sample-count offsets so the timeline cannot drift. `TranscriptionEngine` keeps a per-stream FIFO, a silence
gate and indefinite backoff — an STT outage never stops capture, and chunks queue until it returns.

- **The STT endpoint is configurable** (`meetings.sttBaseURL`). The default is a hosted service; pointing it at a
  local GPU Whisper server that returns the same `{text, words[]}` shape transcribes for free. Plain-HTTP local
  calls need `NSAllowsLocalNetworking` in `Info.plist`, and the request timeout is 120s so a cold model load is
  not cut off.
- `MeetingRecorder` is a `@MainActor` state machine (idle → recording ⇄ paused → stopping → finished). Microphone
  denied is fatal; system audio denied degrades to mic-only. Wake observers and a 5s watchdog rebuild dead
  streams. `abort()` is the synchronous quit path, and a meeting that dies with the app is recovered at next
  launch as "Needs summary" by a crash sweep in `MeetingStore.load()`.
- `MeetingIntelligence` is the live loop: the full transcript plus the current state go to a fast model with a
  structured-output schema, and the whole revised state comes back — action items, and in process-mapping mode a
  swimlane `ProcessModel` whose node ids are stable slugs so the diagram animates rather than redrawing.
  `MeetingCenter.finalize` runs a stronger model once at the end for the polished notes, title, summary and final
  action items, treating your rough notes as the backbone. Re-runnable. **Recording and transcription work with
  no LLM key at all**, and the notes provider can be a local Ollama server instead.
- `MeetingCalendar` names recordings after the Apple Calendar event they overlap — EventKit, read-only, one local
  read, so no calendar API and no per-account token. The best overlapping event wins: scored by overlap, then
  accepted > tentative > unanswered, required seat > optional, call link present, self-organised. Declined
  events, all-day events, holiday and birthday calendars, and anything with no attendees and no call link never
  match. The event title is used **only while the meeting title is still a placeholder**; a name you typed or the
  model wrote is kept, with the event attached underneath.
- **Split** rewrites `transcript.jsonl` (head stays, tail is rebased to zero in a new folder) and trims the m4a
  archives with `AVAssetExportSession`; because the archives hold active time only, a transcript offset is also
  an audio offset. **Join** is the inverse: `AVMutableComposition` lays the streams end to end (a part missing a
  stream contributes silence of its own length, so Me and Them stay aligned across the seam), *then* transcripts
  are shifted by the sum of the earlier parts' lengths. Both drop the combined-call AI notes and re-finalize.
  Nothing is touched if the audio step fails.
- **Translate** sends numbered batches of ≤30 untranslated lines through `LocalTranslator` to an Ollama server
  with `think: false` and a JSON-schema `format`, so a transcript never leaves your network and nothing is
  billed. Lines come back by number; a skipped number is retried next pass, never guessed. Results persist per
  meeting in `translations.json`. **The live meeting drives translation**, not the transcript rail — hanging it
  off the rail's `onChange` meant nothing translated while another tab was showing. Every local call asks Ollama
  for the same `num_ctx` (`localModel.contextTokens`): different sizes per caller make Ollama reload the model
  between calls.
- Storage: `~/Library/Application Support/Udha.AI/Meetings/<yyyyMMdd-HHmmss-slug>/` — `meeting.json`,
  `notes-user.md`, `notes-ai.md`, `process.json`, `transcript.jsonl` (append-only, crash-durable), `audio/`.
- **Permissions.** System audio uses the macOS 14.4+ "System Audio Recording Only" TCC service. There is
  deliberately **no startup probe**, because probing means creating a tap, which means triggering the prompt; it
  fires at the first meeting start instead.

## Recordings

The Videos section: screen and camera capture (`ScreenCaptureSource`, `CameraCaptureSource`, written through an
`AssetWriterPair`), transcription, caption building and editing, and a compositor that renders a landscape and a
vertical master with the presenter as a column of the layout rather than a bubble.

- `RecordingStage` is **stored, not derived** (`capturing`, `needsProcessing`, `transcribing`, `composing`,
  `ready`, `failed`): after a crash the interesting question is "what was in flight?", which a folder of raw
  files cannot answer.
- Captions are burned into the frames by default, because these files get re-uploaded to platforms where a
  sidecar VTT does not travel with them. `CaptionTranslator` gathers cues back into sentences (a gap under 0.35s
  is the same breath; terminal punctuation or 30 words ends one), translates each sentence whole, then spreads
  words across the sentence's span by length and re-cuts — so the cues land on the same beats as the speech.
  Writing the spoken track deletes every translated one.
- `RecordingPublisher` uploads to your own share backend if one is configured. The design constraint is that **no
  third-party storage credential ships in the app**: the app asks your backend (authenticated with the token the
  bridge already holds) for a one-time direct-upload URL, streams the bytes from disk straight to storage, then
  tells your backend what was uploaded. Masters go up over tus, one PATCH per chunk, because plain multipart
  endpoints cap out well below the size of a five-minute master.
- Published titles are reconciled: `Recording.syncedTitle` is what the service last confirmed, a row whose local
  title differs is `titleSyncPending`, and pending titles are re-pushed shortly after launch.

## Machines and system stats

- **`MachineStats`** (`Sessions/SystemStats.swift`) is the shared reading: identity, CPU and load, memory, swap,
  disk, hwmon temperatures, GPU, docker, network rate, top processes, toolchain versions, the relay link, a log
  tail and a ring of connection errors. **Every field is optional-by-omission** — a collector that cannot see
  something leaves it empty, because "0 °C" and "no sensor" must never render alike. `wire` / `init(wire:)` carry
  it over the bridge and are covered by round-trip tests in `tests/main.swift`; the `UInt64` fields are the ones
  JSON is most likely to mangle quietly.
- **`SystemStatsCollector`** is one collector compiled for both platforms. macOS reads `host_statistics`,
  `vm_statistics64`, `sysctl`, `statvfs` and `getifaddrs`; Linux reads `/proc`, `/sys/class/hwmon`, `statvfs`,
  `nvidia-smi` and `docker ps`. It is **stateful on purpose** — CPU and network are rates, which only exist as
  the delta between two samples. Slow probes are cached (`ps` 10s, `docker` 30s, `who` 120s, tool versions 900s)
  so a five-second poll never spawns six processes, and every subprocess has a watchdog: a wedged `docker` must
  not pin the collector.
- **Protocol:** `fetch_stats` → `stats`, behind the `stats` capability, so the same file answers for the Mac and
  for the agent. The reading happens off the main actor; what the main actor knows (relay link, session count) is
  captured before the hop. `RemoteHostClient` asks on connect and every 5s while the section is open, and sets
  `hostStatsUnsupported` when an older agent answers without it.
- **Charts, not bars.** `MachineHistory` is an in-memory ring (720 points per machine) fed by the same 5s samples
  the pane already causes. A series with fewer than two points renders as a dashed baseline saying "collecting",
  never as a dot. Because the monitor only samples while the section is open, each chart is labelled with the
  window it *actually* covers, not a fixed one. The exception is the drop-out chart: connection errors carry
  their own timestamps, so it is bucketed into 24 real hours.
- **Only polls while visible** (`MachineMonitor.isActive`, set by the pane's `onAppear` / `onDisappear`): a closed
  tab costs nothing on either machine.
- **Tailscale is read locally** (`TailscaleCLI`), not over the bridge — a peer's handshake, route and key expiry
  are properties of *this node's* view of the tailnet. `status --json` every 30s, `ping` for latency on up to
  three online peers. This machine's own row is special-cased, since you have no path to yourself.
- **`MachineDirectory`** builds one `MachineSummary` per machine for both the board and the pane, so the two can
  never disagree about whether a box is up. `mobileBridge.knownHosts` remembers every machine ever paired, so a
  box that is switched off keeps its row (offline, with a reason) instead of vanishing exactly when you want to
  know about it.

## Overlay

- `EdgeOverlayPanel` is a borderless, non-activating `NSPanel` at `.statusBar` level, `.canJoinAllSpaces`,
  stationary, pinned to the configured screen edge.
- `EdgeOverlayHostingView` overrides `hitTest` to return nil outside an `interactiveRectProvider` rect, so mouse
  events pass through empty regions to the windows below.
- Rest state is a strip at `overlay.triggerWidth` carrying one capsule tick per session: 14pt red and pulsing for
  *needs you*, 10pt accent for *working*, a 4pt stub for *quiet*. The strip colour is fixed rather than adaptive
  so it never turns white in dark mode. The app icon is the same tick chart.
- Bloom: 100ms hover dwell before opening (so brushing past does not), 220ms collapse debounce (so
  `.onContinuousHover` flicker on a fast crossing does not close it). The list is sized to the panel, not to a
  fixed height — a full desk of sessions should be one glance, never a scroll.
- Clicking a pill calls `showSession(id:)` and posts `.udhaFocusSession` so the main window selects it too. Hover
  only drives the visual highlight; hover-to-focus was removed because it yanked windows around on mouse
  crossings.
- The rename field and the search field both need a **two-step focus dance**: the panel is non-activating, so the
  key gate has to open (`onRenamingChanged` / `onSearchFocusChanged`) *before* first responder is requested, with
  a bail-out timer so a failed grab cannot latch the bloom open.

## Audio capture

`Voice/` is now only the Core Audio plumbing that Meetings and Recordings share. **There is no speech layer.** A
spoken-status engine, an ElevenLabs TTS client, a ConvAI agent and the JSON tool schemas it called through were
all removed deliberately; do not reintroduce one without asking, and note that nothing in `Sessions/` may grow a
model dependency either way (see *Conventions*).

- `AudioCapture` delivers microphone PCM16 mono at a requested sample rate. It is deliberately **not** built on
  `AVAudioEngine`: that binds `inputNode` to whatever the default input was when the graph was instantiated, and
  the device cannot be re-pointed afterwards.
- `AudioPlayer` is the shared playback pipeline; `AudioDeviceLister` enumerates Core Audio devices.
- `AudioInputDevices` reads and writes the *system* default input with live property listeners, because macOS
  drifts the default on its own and every listener in the app follows that one setting. It is what the session
  pane's mic picker and the meeting recorder both bind to.
- `ActivityLog` (`Activity/`) stays: a ring of `ActivityEvent` values (sends, tool invocations, state
  transitions) that the activity meter and the logs read.

## Slack and the inbox

`SlackPoller` (one per workspace) reports new DMs and mentions; `SlackManager` files each in `SlackInbox` —
per-thread history keyed `teamID/channelID`, bounded at 60 threads × 60 messages, persisted to
`Application Support/Udha.AI/slack-inbox.json`. Every stored message carries a `disposition` — "received 9:41"
for something the poller brought in, "sent from Udha" for a reply you wrote here. (The field predates this and
used to record whether the message had been read aloud; the speech layer is gone, the stamp is not.) It is a
forward-only record of what arrived while Udha was running and never backfills from Slack.

## Bridge, remote hosts and udha-agent

### The protocol

`Bridge/` is the **host** half: `RelayClient` (the socket and reconnection), `Auth0Client` (device sign-in),
`MobileBridge` / `MobileBridgeV2` (the verbs). `RemoteHostClient`, in `RemoteHost/`, is the **client** half — `/client`,
`pair_request`, `set_active_instance`, `hello`, `sessions_full` / `sessions_delta`, and the action verbs.

Capabilities are negotiated by name (`stats`, `folders`, `accounts`, `attention_events`, `videos`, …) so a Mac
talking to an older agent switches the missing affordances off rather than failing. New fields ride the wire row
as optional-by-absence.

### Local and remote sessions in one store

Every row the client decodes (`SessionSnapshot(wireRow:)`, the inverse of `wireRow`) is tagged with
`hostName`, and the client reconciles and removes **only rows carrying its own host's name**, never local ones.
Because every UI action funnels through `SessionManager` (`sendInput`, `sendRaw`, `sendKey`, `showSession`,
`terminateSession`, `removeSession`), routing is **per session**: `isRemote(id)` checks the row's `hostName`, and
the overlay, board and palette list and control both machines unchanged.

`showSession` on a remote session opens a Mac terminal running `ssh -t <host> tmux attach -t <name>` — the tmux
name is derived by `TmuxSession.tmuxName(id:label:)`, so this needs no protocol change — and remembers the
terminal **window id** per session plus a 2s debounce, so the overlay, the card and the context menu all raise
one window instead of opening three. Matching by tab title was tried first and fails, because tmux and ssh
rewrite it.

### Session hand-off

Drag a session card onto another machine's column (or right-click → Move) to move it *keeping the conversation*.
`SessionHandoff.plan` reads the assistant's session id and transcript path from the session's sidecar events
file; `stage` rsyncs the working tree (`rsync -az -s`, no `--delete`) and the transcript over SSH into the host's
Claude projects folder, where Claude escapes both `/` and `.` to `-` in the directory name. Only then does
`AppCore.handoffSession` close the local session and send `create_session` with a `resume` field. **Files and
transcript land before the local session closes**, so the chat is never lost.

Two assumptions: the machine's name also resolves as an SSH alias, and the resume path is Claude-only (the
transcript it carries comes from Claude's own status feed).

### `udha-agent`

A SwiftPM executable whose sources under `Sources/udha-agent/Shared/` are **symlinks** into the app's
`Sessions/`, `Bridge/`, `Config/`, `Agents/`, `Activity/`, two `Meetings/` model files and the logger. One pane
reader, one protocol, never a fork. Mac-only code is fenced with `#if !UDHA_AGENT` and Apple frameworks with
`#if canImport(...)`. Linux stand-ins live in `Sources/udha-agent/Linux/`: a `0600` file-backed `KeychainStore`
at `~/.config/udha/secrets.json` (re-read on external change, so a separate `udha-agent login` process is picked
up without a restart) and `NIORelaySocket`, a SwiftNIO/WebSocketKit transport installed via
`RelayClient.socketFactory`.

`install.sh` builds in the official Swift Docker image with `--static-swift-stdlib` (so the binary runs on the
host with only a couple of system libraries — libcurl and libxml2 — present), installs `~/.local/bin/udha-agent`
and a `systemd --user` unit, and
enables lingering. `udha-agent run` idles until signed in. See [self-hosting.md](self-hosting.md) for the
operational walkthrough and `tests/run-e2e.sh` for the mock-relay end-to-end run.

### Linux landmines

All of these are fixed in the shared code. They are listed because each one cost a day and each one will look
like a gratuitous complication to the next person who reads the file.

- **`tail -F` on recent Ubuntu.** `/usr/bin/tail` there is the Rust uutils rewrite, whose `-F` watches the file's
  *directory* and re-reads every other file in it on any change. Twenty sidecar followers in one status directory burn ten
  cores. `TmuxSession.tailBinary` prefers a GNU `tail` (`/usr/bin/gnutail`, package `gnu-coreutils`) wherever one
  exists.
- **`Process.waitUntilExit()` never returns for `tmux new-session`.** The client that daemonises the tmux server
  is left as a zombie and wedges the main actor. `TmuxSession.runTmux(detached:)` gives it null stdio and reaps
  it off-thread.
- **No WebSocket in Foundation on Linux.** `URLSessionWebSocketTask` needs a libcurl built with WebSocket
  support, which distribution builds generally are not. Hence the `RelaySocket` protocol in `RelayClient.swift`,
  with the Foundation socket kept for the Mac and a NIO one installed on Linux.
- **`KillMode=process` in the systemd unit is mandatory.** Without it, restarting the agent kills the whole
  cgroup — which includes the tmux server it spawned, and therefore every supervised session. With it, sessions
  outlive an agent restart.
- `os.Logger`, `Security`, `AppKit`, `Network` and `Combine` are all `canImport`-fenced; `SecRandomCopyBytes`
  becomes `UInt8.random`.

### First-run screens on a remote box

A session that stops on the assistant's theme picker, login-method choice, per-folder trust prompt or fullscreen
nag paints **no footer**, so the pane reader has nothing to anchor on and the session shows as *Starting*
forever. The workaround is to pre-accept the onboarding and trust flags in that machine's assistant config; the
clean fix is for the agent to pre-trust a session's working directory immediately before spawning. A brand-new
folder still stops once, and can be advanced with `tmux send-keys <session> Down Enter`.

## Input lock

Hotel-room mode: keyboard and mouse dead, screen awake, unlock via Touch ID or account password. A deterrent, not
kiosk mode — macOS keeps ⌃⌘Q, the power button and force-restart, and killing Udha over SSH releases the lock,
because the kernel reclaims the tap's mach port on process death. The lock cannot outlive the app.

- `InputLockTap` is a CGEventTap swallowing all human input including `NX_SYSDEFINED(14)` media keys. It runs on
  a **dedicated thread's run loop** — a blocked main loop trips `tapDisabledByTimeout`, which is a silent leak —
  and re-enables itself on `tapDisabledBy*`. `arm(quietFor:)` stops the engaging click or chord from instantly
  opening an auth prompt.
- `InputLockManager` is a `@MainActor` state machine (`unlocked → locking → locked(degraded:) →
  authenticating(passthrough:) → unlocking`, with a sticky `failed(reason)`). Preflights refuse loudly:
  Accessibility missing, no `deviceOwnerAuthentication` (no account password means unrecoverable), or Secure
  Keyboard Entry held by another app — taps cannot see the keyboard then, and Terminal has a menu item for it.
  Touch ID unlocks with the tap fully armed; the password fallback opens a bounded passthrough window whose
  watchdog re-swallows input **then** invalidates the `LAContext`. It holds its own IOPM display-sleep assertion,
  and a 5s heartbeat plus wake observers rebuild a dead tap or go loudly red.
- The curtain (`LockCurtainPanel`) is a frosted full-screen privacy layer on every display, dropped just below
  `.modalPanel` during authentication so the system auth dialog renders above it, and **always dismissed on
  `.failed`** — input is live then, and the user must never click through an invisible desktop.
- The lock chip is a separate click-through panel per display; the edge overlay cannot host it, since its bloom
  needs hover and the mouse is dead.

## Config and secrets

- `~/Library/Application Support/Udha.AI/config.json`, loaded **tolerantly**: the on-disk file is merged onto the
  defaults, missing fields keep their defaults, and a broken file is backed up rather than discarded.
- `AppConfig` sections: `sessions`, `sessionFolders`, `collapsedFolderIDs`, `notifications`, `overlay`,
  `slack`, `mobileBridge`, `awake`, `inputLock`, `meetings`, `localModel`, `recordings`, `recentDirectories`,
  `quickCommands`, `newSession`, `appearance`, `claudeAccounts`, `accountFailover`, plus flags —
  `reclaimTerminalWindows`, `embeddedTerminal`, `hideSessionList`, `verboseLogging`, `statusSidecarEnabled`,
  `staleAfterSeconds` (1800), `hasCompletedFirstRun`.
- Config-file-only, with no Settings row: `meetings.sttBaseURL` (default `https://api.elevenlabs.io`) and
  `localModel` (`baseURL` default `http://localhost:11434`, `contextTokens` 65536).
- Settings controls bind through `ConfigStore.binding(\.some.keyPath)`, which routes writes through `mutate` so
  every change persists the same way. **Config writes are always `config.mutate { … }`** — that block saves.
- `verboseLogging` gates DEBUG lines *in the file log only*: the pane reader and the hook feed emit several a
  second and would otherwise bury every INFO line.
- Secrets live in the macOS Keychain via `KeychainStore`, under a service named after the bundle identifier:
  `elevenlabs_api_key`, `anthropic_api_key` and the bridge's `mobile_bridge_*` tokens.
- Nothing points at a server by default. `mobileBridge.relayURL` / `auth0Domain` / `auth0ClientID` /
  `auth0Audience`, `recordings.shareAPIBaseURL` and `recordings.shareLinkBaseURL` are all empty out of the box —
  no relay, no tenant and no share domain is built in — and the corresponding code never opens a socket while
  they are.

## Conventions

- State uses the Swift `@Observable` macro (`AppCore`, `SessionStateStore`, `ConfigStore`); plain
  `ObservableObject` only where `@Published` is genuinely needed.
- Everything touching `AppCore` is `@MainActor`. Expensive readings hop off it and capture what the main actor
  knows *before* the hop.
- **No LLM in the session-status pipeline.** Status is hooks plus rules. The meeting recorder and the video
  captioner are the only subsystems allowed a model dependency, and both degrade to "works without it".
- Anything under `Sessions/`, `Bridge/`, `Config/`, `Agents/` or `Activity/` is compiled for Linux too. Fence
  Mac-only code with `#if !UDHA_AGENT` and Apple frameworks with `#if canImport(...)`, and remember those files
  are **symlinked** into the agent — editing the copy under `udha-agent/Sources/udha-agent/Shared/` edits the
  app.
- New per-session or per-row fields are optional-by-absence on both the config and the wire, so an older peer and
  an older config file keep decoding.

## Headless verification

The app can be driven and inspected without a pointer, which is how the UI is checked on a locked screen (where
synthetic clicks cannot reach an app, but `screencapture -l <windowid>` still works).

| Flag | What it does |
| --- | --- |
| `-UDHAUIDriver 1` | Listens for distributed notifications and executes UI commands (`section:machines`, `list:toggle`, `palette:toggle`, `select:next`, `appearance:dark`, `accent:purple`, `overlay:bloom`, …). The full list is in `Shell/UdhaUIDriver.swift`. |
| `-UDHAOpenSection <name>` | Opens the window straight onto a section. |
| `-UDHAMachinesSelfTest <seconds>` | Logs a `SELFTEST machine …` block per machine. Give it more than 25s so the keepalive has measured a relay round trip. |
| `-UDHAMeetingSelfTest <seconds>` | Opens the live meeting pane. |
| `-UDHACalendarSelfTest 1` | Runs the calendar backfill and logs one line per recording. |
| `-UDHARecordingSelfTest <seconds>` | Records for that long and processes the result (`-UDHARecordingSelfTestWindow <substring>` picks a window). |
| `-UDHARecordingReprocess YES` | Re-runs processing over the stored recordings. |
| `-UDHANewSessionSheet 1` | Opens the New Session sheet at launch. |
| `UDHA_REMOTE_HOST=<name>` | Auto-selects a remote host at launch (development convenience). |

Other checks: `scripts/verify-status.py` (independent pane reading to diff against the app's),
`python3 tests/attention_mcp_test.py` (the bundled MCP server's protocol), `MOBILE=<mobile client checkout>
tests/run.sh` (wire round-trips plus the cross-repo contract — `tests/main.swift` is not standalone, `run.sh`
builds the client module it imports), and `udha-agent/tests/run-e2e.sh` (agent against a mock relay; the mock
harness itself is not vendored here).
