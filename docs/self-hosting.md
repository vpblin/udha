# Self-hosting the multi-machine setup

Everything in the [What works with zero accounts](../README.md#what-works-with-zero-accounts) list runs with no
server at all. This guide is for the other half: letting the Mac app, a phone, and a headless Linux box all see
and drive the same sessions — so the box keeps working, and stays supervised, with the Mac shut.

You will end up running two things of your own: **a relay** (a small WebSocket server, in [`relay/`](../relay))
and **an Auth0 tenant** that issues tokens for it. Nothing in this repository points at anybody's server, and no
credential ships in the binary.

```
   Mac app  ──┐                            ┌── supervises its own tmux sessions
              ├── wss ──►  your relay  ◄───┤
  phone/iPad ─┘            (auth: your     └── udha-agent on your Linux box
                            Auth0 tenant)       supervises its tmux sessions

   ssh (direct, never through the relay) ──►  terminals, hand-off, file copies
```

The relay only **routes**. It never stores a transcript, never sees your code, and holds nothing but which
instances are online and which client is paired to which host. Terminal attachment, session hand-off and
attachment copies go over plain SSH, machine to machine.

Throughout, `devbox` stands for your Linux machine and `relay.example.com` for your relay's hostname.

---

## 1. Run the relay

[`relay/README.md`](../relay/README.md) is the authority on this step — the Dockerfile, the `docker compose`
invocation, the `.env` variables and the Auth0 application setup all live there. The short version:

```bash
cd relay
cp .env.example .env && $EDITOR .env      # your Auth0 domain + audience
docker compose up -d
curl -fsS http://localhost:8080/health
```

Two things to get right before anything dials in from outside the machine:

- **TLS.** The compose file publishes plain `ws://`. The apps only speak `wss://`, so put a terminator (Caddy,
  nginx, a load balancer) in front of it and point that at port 8080. Bind the published port to `127.0.0.1`
  when the proxy is on the same host.
- **Persistence.** Pairings live in the `relay-data` volume. Keep it, or every machine has to be re-paired after
  an image rebuild.

Any always-on host works — a small VPS is plenty. The relay is idle except when sessions change.

## 2. Set up Auth0

Both the apps and the agent sign in to *your* tenant, and the relay verifies the tokens it issues. Create:

- **An API** whose identifier is the *audience* (using your relay's URL, e.g. `https://relay.example.com`, is the
  convention). **Turn on "Allow Offline Access" on this API.**
- **A Native application** (PKCE, no client secret) for the desktop, the agent and the phone to share.

> **"Allow Offline Access" is the one setting that must be right.** Without it Auth0 issues no refresh token, so
> the access token is all anyone gets — and every host drops off the relay when it expires, with no way back
> except a human re-running the sign-in. If a machine connects fine and then goes quiet hours later, this is
> almost always why.

You will need four values in a moment: the relay URL, the Auth0 domain, the native application's client id, and
the API audience. `relay/README.md` has the callback URLs and grant types to allow.

## 3. Sign the desktop in

**Settings → iPhone** — the pane holding the "Mobile bridge" switch — takes those four values. Fill them in,
enable the bridge, and sign in. The browser round trip happens on the Mac, so there is nothing special to do
here.

You can confirm it took in **Machines**: this Mac's row should show the relay link as connected, with a measured
round-trip time.

The desktop's sign-in also enables remote *discovery* — it asks the relay which of your machines are online, and
auto-connects the first one it finds that is not itself.

## 4. Install `udha-agent` on the Linux box

### Prerequisites on the box

- `tmux`, `git`, and whichever assistant CLIs you want to run there (`claude`, `codex`, `qwen`) — on the **login**
  PATH, not just an interactive shell's. This matters: the systemd unit sets a minimal PATH of
  `~/.local/bin:/usr/local/bin:/usr/bin:/bin`, so anything installed by a version manager needs a symlink into
  `~/.local/bin`.
- **Docker**, to build the agent. `install.sh` compiles inside the official Swift image rather than asking you to
  install a Swift toolchain on the host.
- `python3` if you want the attention MCP tool (usually already there).
- A **GNU `tail`**. Recent Ubuntu ships the Rust uutils rewrite as `/usr/bin/tail`, and its `-F` watches the
  containing *directory*, re-reading every other file in it on any change — twenty session followers in one status
  directory will burn ten cores. Install `gnu-coreutils` (which provides `/usr/bin/gnutail`) and the agent will
  prefer it automatically.

### Build and install

```bash
git clone <your fork or this repo> ~/src/udha
cd ~/src/udha/udha-agent
./install.sh
```

This builds in `swift:6.2-noble` with `--static-swift-stdlib` — so the resulting binary runs on the host with
nothing but a couple of system libraries (libcurl, libxml2) — installs it to `~/.local/bin/udha-agent`,
installs a `systemd --user` unit, and
enables lingering so the service runs with nobody logged in. `./install.sh --no-build` reinstalls an existing
build.

> **Rebuild the agent whenever you change anything under `Sessions/`, `Bridge/` or `Config/`.** Those files are
> symlinked into the agent, so a box running an old binary is running an old pane reader — new classification
> rules, new wire fields and new capabilities simply do not exist there until you rebuild. A stale agent fails
> quietly: capabilities it does not advertise are switched off client-side, and the desktop looks like the
> feature was never built.

### Point it at your relay

Nothing is baked into the binary — the same four values as the desktop:

```bash
udha-agent configure \
  --relay-url wss://relay.example.com \
  --auth0-domain your-tenant.us.auth0.com \
  --auth0-client-id <native app client id> \
  --auth0-audience https://relay.example.com
```

### Sign it in

The agent has no browser, so forward its callback port from a machine that has one:

```bash
ssh -L 8789:localhost:8789 devbox
  udha-agent login          # prints a URL — open it in the forwarding machine's browser
```

Credentials land in `~/.config/udha/secrets.json` (mode `0600`). The running service notices within about 15
seconds and connects; no restart is needed.

### Check it

```bash
udha-agent status                        # instance id, relay, signed in, session count
systemctl --user status udha-agent
tail -f ~/.local/state/udha/udha.log     # also: journalctl --user -u udha-agent
udha-agent accounts                      # Claude login pools, who each is signed in as, headroom
```

### One thing not to change in the unit file

```ini
KillMode=process
```

Without it, `systemctl --user restart udha-agent` kills the whole cgroup — which includes the tmux server the
agent spawned, and therefore **every session running on the box**. With it, an agent restart is invisible to the
work. If you write your own unit, carry that line across.

## 5. Pair from the desktop (and the phone)

With both online, the Mac app's Machines section lists the box. Click its row (or its column header on the
Sessions board) to connect. From the phone app, pick the machine from the list and pair.

Sessions from both machines then live in one board, one command palette and one overlay, each remote row badged
with its machine's name. Create a session on the box with the **Machine** picker in the New Session sheet; the
folder list comes from the box's own recent directories.

## 6. Make the machine's name an SSH alias

**Required.** Several things bypass the relay and talk to the box directly over SSH, and they all build the
command from the machine's name:

| Feature | What it runs |
| --- | --- |
| Open in Terminal (remote session) | `ssh -t devbox tmux attach -t <name>` |
| Embedded terminal (remote session) | the same, wrapped around the attach line |
| Session hand-off | `rsync -az -s` of the working tree and the transcript |
| Image attachments on a remote session | `scp` into the same path on the box |
| "Sign in" for a remote Claude login | `ssh -t devbox claude auth login` |

So `ssh devbox` must work non-interactively, from wherever you are. Two ways:

- **Tailscale (easiest).** Install it on both machines and use MagicDNS: the box's hostname resolves from any
  network, and the machine's reported name already matches. Nothing else to configure.
- **`~/.ssh/config`.** Add a `Host devbox` block with the address, user and key. Works, but you have to keep the
  address current if it is not stable.

Either way, use key auth with no passphrase prompt (an agent-loaded key is fine) — these commands run without a
terminal to type into.

## 7. Optional: services on the box's GPU

None of these are required. Each one moves a paid, cloud-bound feature onto hardware you own.

### Whisper for meeting transcription

Run any HTTP transcription server that accepts an audio chunk and returns:

```json
{ "text": "…", "words": [ { "text": "…", "start": 0.0, "end": 0.42 } ] }
```

That is the shape the hosted default returns, and the client is written against it. A small FastAPI wrapper
around `faster-whisper` with a `large-v3` model is the usual choice. Then set, in
`~/Library/Application Support/Udha.AI/config.json`:

```json
"meetings": { "sttBaseURL": "http://devbox:8770" }
```

Notes from running this in anger:

- Let the model **idle-unload** after ten minutes to give the VRAM back; the client's request timeout is 120s
  precisely so a cold reload is not cut off, and capture is independent of transcription, so chunks queue and
  nothing is lost while it warms.
- A plain-HTTP local call needs `NSAllowsLocalNetworking` in `Info.plist` — already set.
- A warm chunk comes back in a fraction of a second on a current GPU, which is well ahead of real time.

### Ollama for translation, local notes, and Qwen

```bash
# systemd drop-in, or the environment the ollama service runs with
OLLAMA_HOST=0.0.0.0            # otherwise it only listens on localhost
OLLAMA_CONTEXT_LENGTH=65536    # the 4k default truncates agentic runs badly
```

Then in `config.json`:

```json
"localModel": { "baseURL": "http://devbox:11434", "model": "<your model tag>", "contextTokens": 65536 }
```

`contextTokens` is deliberately one value for every local caller — translation, live meeting items, the write-up.
Ollama keeps a model loaded for one `num_ctx`, so two callers asking for different sizes make it reload the model
(tens of seconds) on every switch.

### Qwen Code as a local assistant

[Qwen Code](https://github.com/QwenLM/qwen-code) pointed at that Ollama server gives you an assistant with no
account and no spend. Two box-side details:

- **Symlink `qwen` into `~/.local/bin`.** If it was installed through a Node version manager its shim is on an
  interactive shell's PATH only, and the agent's systemd PATH will not find it.
- Raise `OLLAMA_CONTEXT_LENGTH` as above, or agentic runs truncate mid-task.

Remember that with a local model the approval posture is the *only* thing between the assistant and the disk —
there is no vendor-side refusal behind it. Pick the posture accordingly.

## 8. First-run prompts on the box

A session that stops on the assistant's theme picker, login-method choice, per-folder trust prompt or fullscreen
nag paints **no footer**, so the pane reader has nothing to anchor on and the session sits on **"Starting"**
forever. It is not hung — it is waiting for a keypress nobody is there to make.

Get ahead of it:

1. Run the assistant by hand once per config directory on the box, over SSH, and complete its onboarding. That
   writes the completed-onboarding flags into its config.
2. Trust prompts are **per directory**. The first session in a brand-new folder will still stop once.

To advance one that is already stuck, from the box:

```bash
tmux ls                                    # find the session name
tmux send-keys -t <session> Down Enter     # pick "yes, I trust this folder"
```

The card leaves "Starting" within a couple of polls. If you use a second Claude config directory for separate
work (`CLAUDE_CONFIG_DIR=~/.claude-work`, say), each one needs its own onboarding pass.

## 9. When something is not right

| Symptom | Where to look |
| --- | --- |
| Box never appears in Machines | `udha-agent status` — signed in? relay URL right? Then the relay's own log: does it see the connection? |
| Box appears, then drops after an hour or so | Auth0 API is missing **Allow Offline Access**, so there is no refresh token. |
| Box is online but has no Machines stats, no folders, no login strip | Agent binary predates those capabilities. Rebuild with `install.sh`. |
| Sessions on the box stick on "Starting" | Section 8 — a first-run or trust prompt with no footer. |
| Restarting the agent killed every session | The unit is missing `KillMode=process`. |
| Open in Terminal / hand-off / attachments fail for the box | `ssh devbox` does not resolve or needs interaction — section 6. |
| The box's CPU is pinned by `tail` processes | The uutils `tail` problem — install `gnu-coreutils`. |
| `install.sh` fails | Docker is not running on the box, or the image name in `SWIFT_IMAGE` needs updating. |

## What crosses which wire

Worth knowing before you point this at a network you do not control:

- **Relay:** session metadata (labels, directories, state, the status line, the last question), terminal frames
  while you have a terminal open, and the action verbs. It is your server and your tenant, but it is the one
  component that sees session text.
- **SSH:** working trees during a hand-off, transcripts, image attachments, terminal attachment.
- **Never leaves your machines:** meeting audio and transcripts when the STT endpoint is a local server,
  translations when `localModel` is local, and everything a Qwen session says or does.
- **Leaves your machines only if you configure it:** meeting and caption transcription via a hosted STT key,
  meeting notes via a hosted LLM key, published recordings via your share backend.
