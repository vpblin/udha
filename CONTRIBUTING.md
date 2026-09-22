# Contributing

Thanks for looking. Udha is a small codebase with a few sharp edges; this page is the shortest path to not
getting cut by them.

## Build

```bash
open Udha.AIDesktop.xcodeproj     # one scheme: Udha.AIDesktop
./run.sh                          # or: build, verify the bundle, launch
./run.sh --rebuild                # force a clean build
```

macOS 15.6+, Apple Silicon, Xcode 15+, `tmux` on `PATH`. Scripted builds must pass
`-skipPackagePluginValidation` (SwiftTerm ships a build-tool plugin Xcode otherwise wants a human to approve).
Put your own `UDHA_BUNDLE_ID` and `DEVELOPMENT_TEAM` in `Local.xcconfig` — it is git-ignored, and it is the only
file that should ever carry them.

Checks worth running before a PR:

```bash
python3 tests/attention_mcp_test.py       # bundled MCP server protocol
swift build --package-path udha-agent     # the agent package still compiles
MOBILE=<mobile client checkout> tests/run.sh   # wire round-trips + the cross-repo contract
```

`tests/run.sh` is the entry point for the wire tests — `tests/main.swift` is not standalone, it
`@testable import`s a `UdhaClient` module that `run.sh` builds from the mobile client's `Bridge/`
sources. Without a checkout to point `MOBILE` at, skip it; the other two run anywhere.

## Where things live

Everything below is under `Udha.AIDesktop/` unless it is a top-level directory.

`Sessions/` tmux glue, pane reader, hook sidecar, state store · `Shell/` the window · `Overlay/` the edge UI and
the lock chip · `DesignSystem/` tokens and primitives · `Meetings/` and `Recordings/` the two capture pipelines ·
`Voice/` the Core Audio capture and playback those two share · `Machines/` fleet vitals · `Bridge/` the host half
of the relay protocol and `RemoteHost/` the client half · `Slack/` poller and inbox · `Security/` and `Hotkey/`
the input lock · `Config/` the tolerant JSON store and the Keychain wrapper · then, at the top level,
`udha-agent/` the headless Linux build and `relay/` the self-hostable relay.

New SwiftUI views go in the relevant subsystem folder and are picked up automatically — the target uses a
file-system synchronized group, so the project file does not need touching.

[docs/architecture.md](docs/architecture.md) explains the parts in depth, including the several places where the
obvious simplification has already been tried and has already broken something. Read the classification and Linux
sections before changing anything there.

## Three rules

### 1. No LLM in the session-status pipeline

What a session card says is derived from the assistant's own hook and statusLine feed and from rule-based parsing
of the rendered pane. Nothing in `Sessions/` may call a model to decide a state, summarize output, or write a
status line. A summarizer lived there once and was removed deliberately; it made status slow, expensive, and
occasionally confidently wrong about what a session was doing.

The meeting recorder and the video captioner are the only subsystems allowed a model dependency, and both must
keep working — capture, transcript, local files — with no key configured at all.

### 2. Shared code compiles for Linux

Anything under `Sessions/`, `Bridge/`, `Config/`, `Agents/` or `Activity/` is **symlinked** into
`udha-agent/Sources/udha-agent/Shared/` and compiled for Linux. Editing the copy under `udha-agent/` edits the
app; there is one implementation of the pane reader and one of the protocol, and it must stay that way.

- Fence Mac-only code with `#if !UDHA_AGENT` (meetings, recordings, Terminal.app, anything with a window).
- Fence Apple frameworks with `#if canImport(AppKit)` / `canImport(Security)` / `canImport(Combine)` / …
- Do not reach for `os.Logger`, `SecRandomCopyBytes`, `NSWorkspace` or AppleScript in shared files.
- Run `swift build --package-path udha-agent` before opening a PR that touches any of them.
- New fields on a session row or in the config must be **optional-by-absence** on both the wire and in
  `Codable`, so an older peer and an older config file keep decoding. A new capability gets a name, and clients
  must switch the feature off when a host does not advertise it.

### 3. Never add a hostname, an email address, or an organisation name

No machine names, IPs, tailnet names, personal or company email addresses, client or employer names, Auth0
tenants or client ids, relay URLs, bundle ids or team ids — not in code, comments, tests, docs, fixtures or
commit messages. Every server-shaped value is a config field that ships empty, and every example uses a
placeholder: `devbox`, `relay.example.com`, `your-tenant.us.auth0.com`, `you@example.com`, `~/projects/work`,
`~/.claude-work`.

If a feature needs a server, it needs a setting, a documented shape for what the endpoint must return, and code
that stays entirely inert while the setting is empty.

## Pull requests

- One change per PR, with a description of what you observed before and after. UI changes are much easier to
  review with a screenshot; classification changes are much easier to review with the pane text you were reading.
- If you change the pane reader, say which version of which assistant CLI you tested against. These rules track
  upstream terminal output and break when it changes — a captured frame in the PR body is the most useful thing
  you can include.
- Keep comments about *why*. The codebase leans on them heavily, because most of the non-obvious code is
  non-obvious for a reason that is invisible from the code itself.
