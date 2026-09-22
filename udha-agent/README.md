# udha-agent

Udha without the window. Runs on a headless Linux box and serves its
tmux/Claude sessions to the Udha phone/iPad app through the same relay the Mac
uses — so you can develop against the box from your phone with the laptop shut
off. It appears in the app as its own paired machine, named after the box's
hostname unless you set `--name`. Sessions, live status, approve/deny, terminal
frames, diffs and agents all work; meetings/videos stay on the Mac.

## How it's built
Compiles the Mac app's own session engine + mobile bridge for Linux — the files
under `Sources/udha-agent/Shared/` are **symlinks** into `../Udha.AIDesktop`, so
there is one pane reader and one protocol, never a fork. Mac-only pieces
(meetings, recordings, Terminal.app, Keychain) are `#if`-fenced out with
`-DUDHA_AGENT`; Linux stand-ins live in `Sources/udha-agent/Linux/`
(file-backed secret store; a SwiftNIO WebSocket, because Ubuntu's libcurl has no
WebSocket support).

## Build & install (on the box)
```
cd <your checkout>/udha-agent
./install.sh                 # builds in the swift:6.2-noble container, installs the user service
```
The binary links the Swift runtime statically, so it runs on the host with only
a couple of system libraries (libcurl, libxml2) present. Installs to
`~/.local/bin/udha-agent` + a
`systemd --user` service (`Restart=always`, lingering enabled → runs headless).

## Point it at your relay (one time)
Nothing is baked into the binary. Tell it which relay to join and which Auth0
tenant issues tokens for it — the same four values the Mac app takes under
Settings → iPhone:
```
udha-agent configure \
  --relay-url wss://relay.example.com \
  --auth0-domain your-tenant.us.auth0.com \
  --auth0-client-id <native app client id> \
  --auth0-audience https://relay.example.com
```

## Sign in (one time)
The agent needs an Auth0 token for the relay. It has no browser, so forward the
callback port from a machine that does:
```
ssh -L 8789:localhost:8789 <box>
  udha-agent login            # prints a URL — open it in the forwarding machine's browser
```
Credentials land in `~/.config/udha/secrets.json`. The running service notices
within 15s and connects — no restart needed.

> **Prerequisite for staying connected:** enable **Allow Offline Access** on the
> relay API in the Auth0 dashboard. Without it Auth0 issues no refresh token,
> so the agent (like the Mac bridge) drops when the access token expires and
> can't reconnect. This is the one thing that must be done in Auth0, once.

## Commands
```
udha-agent run        # what systemd runs; idles until signed in, then connects
udha-agent configure  # relay URL / Auth0 tenant (see above)
udha-agent login      # one-time sign-in (see above)
udha-agent logout     # forget relay credentials
udha-agent status     # instance id, relay, sign-in state, session count
udha-agent accounts   # every Claude login pool: who each dir is signed in as, and its headroom
```
Service: `systemctl --user {status,restart,stop} udha-agent`,
logs `~/.local/state/udha/udha.log` and `journalctl --user -u udha-agent`.

## Test
`tests/run-e2e.sh` drives the agent through a mock relay (pair → hello → create
session → live classification → terminal frame → close) with a fake token,
restoring your real config/secrets afterwards. Linux only. The driver,
`tests/e2e-mock.js`, is here; the mock relay server it talks to is **not
vendored in this repository** — point `HARNESS` at a directory holding a
`mock-relay.js`, with a sibling `relay-server/node_modules` providing `ws`, and
run it on a free port: `HARNESS=<harness dir> PORT=8095 tests/run-e2e.sh`.

## Use it from the phone/iPad
1. Configure + sign in (above) so the box is online on the relay.
2. Open the Udha app → it lists your machines → pick the box and pair.
3. Create/observe sessions on the box. The Mac can be off.

## Several Claude logins for one tree

A session on a tree that lists `alternates` under its `claudeAccounts` entry
moves to the emptiest login when the one it is on hits its usage limit
([docs/architecture.md → Claude login pools](../docs/architecture.md#claude-login-pools)
has the mechanics). To add a login on this box:

```
scripts/add-claude-login.sh ~/.claude-work work-2 dev2@example.com
systemctl --user restart udha-agent      # the pool is read at start
udha-agent accounts                      # check it is signed in and has headroom
```

Sign-in is interactive (a URL to open anywhere, a code to paste back), so run
it over SSH.
