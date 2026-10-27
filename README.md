# Udha

Udha is a native macOS app that supervises long-running AI coding sessions. Every session runs inside its own
tmux session — Claude Code, Codex (ChatGPT), Qwen Code, or any shell command you like — and Udha watches all of
them at once: it reads each pane, works out whether the assistant is thinking, using a tool, waiting on your
approval or finished, and shows the answer as a strip of ticks welded to the right edge of your screen that
blooms into a panel when you hover it. From the one window you get a board of every session on every machine, a
terminal embedded next to the session facts, a Granola-style meeting recorder with live transcript and notes, a
screen/camera recorder with burned-in captions, a Slack inbox, and a fleet dashboard with live CPU, memory, disk,
GPU and temperatures. A companion headless Linux binary, `udha-agent`, runs the same session engine on a box
so that box keeps working — and stays supervised from your phone — with the Mac shut.

There is deliberately **no LLM in the session-status pipeline**. Status comes from Claude Code's own hook and
statusLine feed plus rule-based parsing of the rendered terminal pane. What a session card says is text lifted
verbatim from the session itself.

---

## What works with zero accounts

Everything below is local. No server of ours, no key, no sign-in, no network call Udha makes on its own:

- **Sessions.** Spawn, name, reorder, duplicate, rename, group into folders, hide, terminate. Each one is a real
  tmux session you can attach to from any terminal; quitting Udha leaves the work running.
- **The overlay.** The right-edge tick strip and its bloomed panel of session pills.
- **The embedded terminal.** A live terminal for the selected session inside Udha's window (a second tmux client,
  never an owner).
- **Classification.** The hook/statusLine sidecar and the pane reader, giving you phase, current tool, subagent
  count, context window use and cost for Claude sessions, and pane-derived state for Codex and Qwen.
- **The board and the command palette.** Search, multi-select, ⌘K, the menu-bar extra, attention inbox.
- **Screen and camera recording.** Capture, compositing into landscape and vertical masters, caption editing.
  (Automatic caption text needs transcription — see below. Capture itself never touches the network.)
- **Input lock.** Keyboard and mouse dead, screen awake, Touch ID to release.
- **Qwen on your own hardware.** Point [Qwen Code](https://github.com/QwenLM/qwen-code) at an Ollama server you
  run and the model answering is a machine you own: no account, no spend, no vendor.

Claude Code and Codex are of course signed in however you normally sign them in — Udha launches the binary, it
does not proxy your assistant.

## What needs a key or a server

Each of these is off until you fill it in, and the corresponding code never opens a socket while it is empty.

| Feature | What it needs |
| --- | --- |
| Meeting and video-caption transcription | **Either** an **ElevenLabs** API key (Scribe) **or** a local Whisper server you run — any HTTP endpoint returning Scribe's `{text, words[]}` shape. Point `meetings.sttBaseURL` at it. |
| Meeting notes, action items, process diagram, "ask about this call" | **Either** an **Anthropic API key** **or** a local **Ollama** server. Recording and transcription work with neither. |
| Transcript / caption translation | An **Ollama** server (`localModel.baseURL`). |
| Phone bridge, remote machines, session hand-off | **Your own relay server** plus **your own Auth0 tenant**. A self-hostable relay is in [`relay/`](relay/); the walkthrough is [docs/self-hosting.md](docs/self-hosting.md). |
| Publishing a recording to a share page | **Your own upload backend** (`recordings.shareAPIBaseURL`) and the base URL its pages are served from (`recordings.shareLinkBaseURL`). Both ship empty and no domain is built in, so publishing is off and recordings stay local files. |
| Slack inbox | A Slack token per workspace. |

Nothing in this repository points at anyone's servers, and no credential ships in the binary.

---

## Requirements

- macOS 15.6 or later, Apple Silicon — that is the project's deployment target
  (`MACOSX_DEPLOYMENT_TARGET` in `Udha.AIDesktop.xcodeproj`).
- Xcode 15 or later.
- `tmux` — `brew install tmux`. Udha looks in `/opt/homebrew/bin/tmux`, `/usr/local/bin/tmux`, `/usr/bin/tmux`.
- Whichever assistant CLI you intend to supervise (`claude`, `codex`, `qwen`) on your `PATH`.
- `python3` on the login `PATH` if you want the attention MCP tool (ships with macOS).

## Build & run

1. Open `Udha.AIDesktop.xcodeproj`. One scheme: `Udha.AIDesktop`.
2. Optional but recommended: create `Local.xcconfig` next to `Udha.xcconfig` (git-ignored) with your own values:

   ```
   UDHA_BUNDLE_ID = com.yourname.udha
   DEVELOPMENT_TEAM = ABCDE12345
   ```

   With no team Xcode signs the Debug build to run locally, which is enough to try it. A real team is required
   for the Keychain data-protection path and for distributing the app. The bundle id also names the Keychain
   service and the `os.Logger` subsystem, so give it your own if you plan to keep two builds side by side.
3. Build and run. First launch is a two-step sheet: an optional ElevenLabs key (transcription only — skip it
   and meetings still record) and a "you're set" page. The permission prompts — Apple Events to Terminal.app,
   the microphone, system-audio recording, Accessibility — are asked for by the feature that needs them, the
   first time you use it, never at launch.

`./run.sh` is a resilient launcher for day-to-day use: it builds incrementally, verifies the bundle
(`codesign --verify` plus a readable `Info.plist`) and rebuilds from scratch if macOS pruned the Debug build out
from under it, then launches. `./run.sh --rebuild` forces a clean build.

The only Swift Package dependency is [SwiftTerm](https://github.com/migueldeicaza/SwiftTerm) 1.20.x, used by the
embedded terminal and imported in exactly one file. SwiftTerm 1.20 ships a build-tool plugin that Xcode wants a
human to approve once, so every scripted build passes **`-skipPackagePluginValidation`** — without it a headless
build fails at *Validate plug-in "SwiftTermBuildInfoPlugin"*.

The app sandbox is disabled on purpose: Udha drives tmux, reads panes, sends Apple Events to Terminal.app and
installs a CGEventTap for the input lock.

---

## The window

One window, six sections, all reachable from ⌘K.

**Sessions.** A board with one column per machine — a sticky header carrying that machine's live dot, session
count, link state and CPU, then its sessions as cards. A card shows the assistant and model, a state dot that
pings while the turn is live, the state word in its colour, and the line the turn ended on. Cards drag between
columns to hand a session to another machine, taking its working tree and its conversation with it. Selecting one
opens the session pane: the header (name, path, model, mic picker, Terminal | Details, Run agent, Open in
Terminal), a *Running on* card, a red *Waiting on you* card whenever the session needs an answer, the session
fact list, and a send box pinned to the bottom. Drop an image anywhere on the pane and its path is staged into
the next message — a tmux pane cannot be handed bytes, so a path the assistant reads is the whole trick.

**Meetings.** Microphone and system audio captured as two independent streams (so no diarization is needed),
chunked on silence boundaries, transcribed, and turned into live notes, action items and — in process-mapping
mode — a swimlane diagram that animates as the process is described. A live *Ask* pane answers questions from
the transcript without touching the call. Recordings can be split (you forgot to stop) or joined (you stopped by
mistake), translated line by line, and named automatically after the Apple Calendar event they overlap.

**Agents.** A reusable prompt stored as a plain `.md` file with `name` / `description` / `icon` frontmatter.
Running one spawns a fresh session in a folder you pick and pastes the prompt in. A handful ship built in and are
restored if you delete them; your own are never touched.

**Inbox.** Slack DMs and mentions, filed per thread as they arrive, each stamped with when Udha saw it
("received 9:41") or that you answered it from here ("sent from Udha"). You can reply from the pane. It is a
forward-only record of what arrived while Udha was running, not a Slack mirror.

**Videos.** The screen/camera recorder: countdown, capture, transcription, caption editing, compositing to a
landscape and a vertical master with captions burned in, optional translation of the caption track, joining
clips, and publishing to a share backend if you have configured one.

**Machines.** One card per machine Udha supervises — this Mac and every box running `udha-agent` — with CPU,
memory, disk, GPU, per-sensor temperatures, docker, network rate, top processes, toolchain versions, the relay
link, the tailnet path and the tail of that machine's supervisor log. Every number carries a sparkline of its
recent shape. It only polls while the section is open.

**The overlay.** A near-black strip one hair wide against the screen edge, carrying one capsule tick per session:
tall and red and pulsing when a session wants you, a shorter accent bar while it works, a stub when it is quiet.
Hover for 100 ms and it blooms into a card of session pills; click one to raise that terminal. Empty regions pass
clicks through to whatever is behind.

---

## How session status is decided

Three sources, in precedence order, all rule-based.

1. **Hook + statusLine sidecar** (sessions Udha launched, Claude only). Claude is spawned with a generated
   settings file and two `sh` hook scripts that append payloads to a per-session JSONL and overwrite a status
   file. This gives exact tool names, unambiguous turn ends, permission prompts, real context-window usage and
   spend. A reattached session keeps an existing feed, so restarting Udha does not orphan a live session.
2. **Pane reader** (works for every Claude session). `tmux capture-pane -pe` is anchored on the footer line and
   read relative to it: `esc to interrupt` means streaming, `⏸ plan mode on` means planning, the spinner shape
   separates thinking from finished, `⏺ Tool(args)` is the current tool, `◯ …` are subagents. Escapes are kept
   because Claude renders ghost prompt suggestions in ANSI dim and text you actually typed in bright white, and
   that is the only way to tell them apart. Full-pane overlays that replace the footer are detected and the
   previous phase is held rather than guessed at.
3. **Codex and Qwen pane rules**, and the original regex classifier for plain shell commands (y/n prompts,
   `Error:`, `Traceback`, …), both behind a stability filter so a single repaint frame cannot flip a state.

Claude-only plumbing is gated on which assistant a session runs, not on the command string. Codex and Qwen get no
sidecar, no context percentage and no cost, and the Claude pane reader is kept off their panes — a detail that is
load-bearing rather than tidy, for reasons [docs/architecture.md](docs/architecture.md) spells out.

---

## Remote machines (`udha-agent`)

`udha-agent/` is Udha without the window: a SwiftPM executable whose sources are **symlinks** into the app's own
`Sessions/`, `Bridge/`, `Config/`, `Agents/` and `Activity/`, so the box runs the same session engine, the same
pane reader and the same protocol — one implementation, never a fork. Mac-only code is fenced out at compile
time. It connects to your relay as its own instance, and both the Mac app and the phone app see it as a second
machine: create sessions on it, watch them classify live, approve prompts, attach a terminal, hand sessions to
and from it — with the Mac off.

Build and install it on the box with `udha-agent/install.sh` (it builds in the official Swift Docker image with a
statically linked stdlib, installs to `~/.local/bin/udha-agent` and enables a `systemd --user` service with
lingering on). The end-to-end walkthrough — relay, Auth0, sign-in over an SSH port-forward, the SSH alias
requirement, optional GPU services, and the first-run trust prompts that otherwise leave a session stuck on
"Starting" — is **[docs/self-hosting.md](docs/self-hosting.md)**.

---

## Configuration and secrets

- Config: `~/Library/Application Support/Udha.AI/config.json`. Loaded tolerantly — the file on disk is merged
  onto the defaults, missing fields keep their default, and a broken file is backed up rather than thrown away.
  A few knobs (`meetings.sttBaseURL`, `localModel`) are config-file-only; everything else has a Settings row.
- Secrets: the macOS Keychain, under a service named after the bundle identifier. The accounts are
  `elevenlabs_api_key`, `anthropic_api_key` and the bridge's `mobile_bridge_*` tokens.
- Application data: `~/Library/Application Support/Udha.AI/` — `Agents/*.md`, `Meetings/<stamp-slug>/`,
  `Recordings/`, `slack-inbox.json`, the attention inbox.
- Logs: `~/Library/Logs/Udha.AI/udha.log`, plus an `os.Logger` subsystem named after the bundle identifier.
  `verboseLogging` adds DEBUG lines to the file log only.
- Runtime scratch: `/tmp/udha/` — pipe-pane logs, the status sidecar feed, staged attachments.

## Architecture

**[docs/architecture.md](docs/architecture.md)** is the maintainer's reference: the directory layout, the design
system, the classification pipeline with the gotchas that make it work, the status model, the Claude login pool,
the embedded terminal, the meetings pipeline, the stats collector, the relay protocol and the Linux port's
landmines.

## Status and limitations

Udha is early, it was built for one person's desk first, and it shows in places.

- **macOS 15.6+, Apple Silicon only.** No Intel build, no App Store build, no notarized release — you build it
  from source and sign it yourself.
- **English-only UI**, and the classifier's rules are written against the English output of the assistant CLIs.
  A localized Claude Code would not be read correctly.
- **The classifier tracks upstream CLIs.** Claude Code, Codex and Qwen Code change their footers and spinners;
  when they do, the pane reader needs a matching change. It degrades to "Starting" or a stale phase rather than
  lying loudly, but it does degrade.
- Remote *Open in Terminal* only recognises terminal windows Udha itself opened.
- If more than one remote machine is online, only the first discovered auto-connects; click another to switch.
- The Slack inbox never backfills history, so a fresh install starts empty.
- Session hand-off assumes the machine's name also resolves as an SSH alias.

## Licence

MIT — see [LICENSE](LICENSE).
