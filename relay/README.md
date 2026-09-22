# Udha relay

A ~1000-line Node WebSocket relay. It is the only piece of Udha that has to be
reachable from the internet, and it is deliberately dumb: it authenticates both
ends against your Auth0 tenant, checks they belong to the same account, and
forwards JSON between them. It never reads a message's contents, stores no
session data, keeps no database, and holds exactly one file on disk — the list
of which machines each account has paired. That is what lets a Mac in your
flat and an iPad on a train reach each other without either one opening a port,
and why self-hosting it is a small job.

```
    host                             relay                          client
 ┌───────────────┐                ┌──────────┐              ┌─────────────────┐
 │ Udha.app (Mac)│  wss:// /home  │          │ wss:// /client│ Udha on iPad    │
 │ udha-agent    │───────────────▶│  routes  │◀──────────────│ Udha.app as a   │
 │ (Linux box)   │   ?token=JWT   │  by user │   ?token=JWT  │ remote client   │
 └───────────────┘   &instanceId  │  + inst. │               └─────────────────┘
        ▲                         └────┬─────┘                        │
        │                              │ APNs (optional)              │
        └──── supervises tmux ─────    └──────────────▶ backgrounded iPhone
```

Both sides dial *out*. The relay pairs them by Auth0 `sub` — a connection can
only ever see machines belonging to the same login — and by `instanceId`, so a
client that has subscribed to one machine does not get another one's traffic.

---

## What you need

- A host on the internet with Docker (a $5 VPS is plenty — the relay is idle
  most of the time and the traffic is small JSON frames).
- A DNS name pointing at it, and a TLS certificate. The apps only speak
  `wss://`.
- A free Auth0 tenant.

---

## 1. Auth0 setup

Two objects: an **API** (what the relay validates tokens against) and a
**Native application** (what the desktop and `udha-agent` sign in through).

### 1a. Create the API

1. Auth0 Dashboard → **Applications → APIs → Create API**.
2. **Name**: anything, e.g. `Udha relay`.
3. **Identifier**: a URI you control the look of — it is an opaque string, it
   does not have to resolve. `https://relay.example.com` is the conventional
   choice. **This exact string becomes `AUTH0_AUDIENCE` and the `audience` you
   enter in the app.** It cannot be changed later.
4. **Signing Algorithm**: `RS256` (the default). The relay only accepts RS256.
5. Create it, then open the API's **Settings** tab and turn on:
   - **Allow Offline Access** — ***this is the one that bites.*** Without it
     Auth0 silently drops `offline_access` from the request and issues no
     refresh token. Everything appears to work for about a day, then the access
     token expires and the bridge goes "disconnected" with no useful error. See
     [Troubleshooting](#the-bridge-says-disconnected-after-a-while).
   - **Token Expiration**: 86400 seconds is fine.

### 1b. Create the Native application

1. **Applications → Applications → Create Application**.
2. **Name**: e.g. `Udha`. **Type**: **Native**. (Native, not SPA and not
   Machine-to-Machine: the desktop and the agent both do a loopback PKCE flow
   with no client secret.)
3. Open its **Settings** tab and set:

   | Field | Value |
   | --- | --- |
   | **Allowed Callback URLs** | `http://localhost:8789/callback` |
   | **Allowed Logout URLs** | `http://localhost:8789/callback` |

   Port **8789** is what both the desktop app and `udha-agent login` bind for
   the one-shot callback listener; it is not configurable in the UI. The
   listener binds `127.0.0.1` only. Leave *Allowed Web Origins* and *Allowed
   Origins (CORS)* empty — nothing here runs in a browser.

4. **Advanced Settings → Grant Types**: `Authorization Code` and
   `Refresh Token` must both be ticked. (Native apps get both by default;
   check anyway, because an untick here produces the same
   "disconnected-after-a-day" symptom as a missing Allow Offline Access.)
5. **Advanced Settings → OAuth**: leave *OIDC Conformant* on.
6. Copy the **Client ID**. You will paste it into the app; the relay itself
   never sees it.

### 1c. Refresh token rotation (recommended)

**Applications → your app → Settings → Refresh Token Rotation**:

- **Rotation**: enabled
- **Reuse Interval**: `30` seconds (covers a retry after a dropped response)
- **Absolute Expiration**: off, or long — a box left running for a month should
  not need a human at a keyboard
- **Inactivity Expiration**: 30 days or more

The clients handle rotation transparently: each refresh returns a new refresh
token and they store it. A refresh that fails with `invalid_grant` is the only
thing that clears the stored token and forces a fresh sign-in.

### 1d. Email in logs (optional, cosmetic)

An Auth0 *access* token carries no `email` claim, so by default the relay logs
a truncated user id. If you want readable log lines, add an Action
(**Actions → Library → Build Custom**, trigger *Login / Post Login*):

```js
exports.onExecutePostLogin = async (event, api) => {
  api.accessToken.setCustomClaim("https://relay.example.com/email", event.user.email);
};
```

then set `AUTH0_EMAIL_CLAIM` to that same namespaced string. Nothing depends on
it.

---

## 2. Run it

```bash
cd relay
cp .env.example .env
$EDITOR .env          # AUTH0_DOMAIN and AUTH0_AUDIENCE are the only required ones
docker compose up -d
docker compose logs -f
```

You should see:

```
[...] Push notifications disabled (no APNS_* vars set)
[...] Udha relay v2.0.0
[...] Listening on 0.0.0.0:8080
[...] Auth mode: auth0
[...] Auth0 domain: your-tenant.us.auth0.com
[...] Auth0 audience: https://relay.example.com
[...] Auth0 issuer: https://your-tenant.us.auth0.com/
[...] APNs enabled: no
[...] Data directory: /data
[...] Endpoints:
[...]   Health:  GET https://relay.example.com/health
[...]   Host:    wss://relay.example.com/home?token=<JWT>&instanceId=<ID>
[...]   Client:  wss://relay.example.com/client?token=<JWT>
```

A missing required variable is a hard stop, not a warning:

```
Udha relay cannot start — fix the configuration:
  • AUTH0_DOMAIN is not set — your Auth0 tenant, e.g. your-tenant.us.auth0.com
```

Without Docker: `npm ci && npm start`, with the same variables in the
environment. Node 18+.

### Environment variables

Required:

| Variable | What it is |
| --- | --- |
| `AUTH0_DOMAIN` | Your tenant, no scheme — `your-tenant.us.auth0.com`. |
| `AUTH0_AUDIENCE` | The Identifier of the API from step 1a. |

Everything else is optional and documented inline in
[`.env.example`](.env.example):

| Variable | Default | Notes |
| --- | --- | --- |
| `AUTH_MODE` | `auth0` | `insecure-dev` accepts any token — localhost and tests only. |
| `AUTH0_ISSUER` | `https://<domain>/` | Override for an Auth0 custom domain. |
| `AUTH0_JWKS_URI` | `https://<domain>/.well-known/jwks.json` | Same. |
| `AUTH0_EMAIL_CLAIM` | *(unset)* | Namespaced claim to read `email` from, for logs. |
| `JWKS_REQUESTS_PER_MINUTE` | `10` | Keys are cached an hour regardless. |
| `PORT` | `8080` | Listening port inside the container. |
| `BIND_ADDRESS` | `0.0.0.0` | `127.0.0.1` when a local proxy fronts it. |
| `PUBLISH_ADDRESS` | `0.0.0.0` | compose only: host interface to publish on. |
| `PUBLISH_PORT` | `8080` | compose only: host port. |
| `PUBLIC_URL` | `ws://localhost:<PORT>` | Only used for the startup banner. |
| `DATA_DIR` | `<repo>/data`, `/data` in Docker | Holds `paired-instances.json`. |
| `PING_INTERVAL_MS` | `30000` | Keepalive; a missed round terminates the peer. |
| `PAIRING_TIMEOUT_MS` | `30000` | How long a `pair_request` waits on the host. |
| `ATTENTION_PRESENCE_TTL_MS` | `45000` | Push suppression while a phone is looking. |
| `RATE_LIMIT_MAX_ATTEMPTS` | `10` | Per-IP upgrade attempts… |
| `RATE_LIMIT_WINDOW_MS` | `60000` | …per this window. |
| `APNS_KEY_ID` | *(unset)* | 10-char APNs key id. Push is off unless the set below is complete. |
| `APNS_TEAM_ID` | *(unset)* | Apple Developer Team ID. |
| `APNS_BUNDLE_ID` | *(unset)* | Bundle id of *your* iOS build — this is the APNs topic. |
| `APNS_KEY_PATH` | *(unset)* | Path to the `.p8` inside the container. |
| `APNS_KEY` | *(unset)* | The `.p8` contents inline (`\n` for newlines), instead of a path. |
| `APNS_PRODUCTION` | `false` | `false` = sandbox (Xcode build), `true` = TestFlight/App Store. |
| `APNS_EXPIRATION_SECONDS` | `300` | How long APNs keeps retrying. |

Push is entirely optional. Only the iOS app registers a device token; the
desktop and `udha-agent` never receive pushes. Leave the `APNS_*` block unset
and you get `Push notifications disabled (no APNS_* vars set)` and a fully
working relay.

---

## 3. Behind TLS

The relay speaks plain HTTP/WS. Terminate TLS in front of it. Set
`PUBLISH_ADDRESS=127.0.0.1` in `.env` first, so the raw port is not reachable
from outside.

### Caddy

Caddy proxies WebSockets with no extra configuration and gets a certificate on
its own:

```caddyfile
relay.example.com {
    reverse_proxy 127.0.0.1:8080
}
```

### nginx

nginx needs to be told about the upgrade, and needs its read timeout raised
past the relay's 30 s keepalive or it will cut idle connections:

```nginx
map $http_upgrade $connection_upgrade {
    default upgrade;
    ''      close;
}

server {
    listen 443 ssl http2;
    server_name relay.example.com;

    ssl_certificate     /etc/letsencrypt/live/relay.example.com/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/relay.example.com/privkey.pem;

    location / {
        proxy_pass         http://127.0.0.1:8080;
        proxy_http_version 1.1;
        proxy_set_header   Upgrade    $http_upgrade;
        proxy_set_header   Connection $connection_upgrade;
        proxy_set_header   Host       $host;
        proxy_set_header   X-Real-IP  $remote_addr;

        # Longer than PING_INTERVAL_MS, or idle sockets get cut.
        proxy_read_timeout  3600s;
        proxy_send_timeout  3600s;
    }
}
```

Your URL is then `wss://relay.example.com` — that is what goes in the apps.
Put the same value in `PUBLIC_URL` so the startup banner prints something you
can copy.

Note on `X-Real-IP`: the relay rate-limits by `request.socket.remoteAddress`,
which behind a proxy is the proxy. If you need per-client rate limiting, do it
in the proxy.

---

## 4. Point the apps at it

Each machine needs four values: the **relay URL**, the **Auth0 domain**, the
**Auth0 client id** (from step 1b) and the **audience** (from step 1a). Every
one of them is configuration; nothing is compiled in.

### macOS desktop

**Settings → iPhone** — the pane holding the **Mobile bridge** switch:

| Field | Value |
| --- | --- |
| Relay URL | `wss://relay.example.com` |
| Auth0 domain | `your-tenant.us.auth0.com` |
| Auth0 client ID | the Native app's Client ID |
| Auth0 audience | `https://relay.example.com` |

Turn the bridge on and click **Sign in**. A browser opens to Auth0 and comes
back to `http://localhost:8789/callback`. The status should go to *connected*.

These land in `~/Library/Application Support/Udha.AI/config.json` under
`mobileBridge` (`relayURL`, `auth0Domain`, `auth0ClientID`, `auth0Audience`);
the tokens go to the Keychain, never the config file.

### A Linux box running udha-agent

```bash
udha-agent configure \
  --relay-url        wss://relay.example.com \
  --auth0-domain     your-tenant.us.auth0.com \
  --auth0-client-id  YOUR_CLIENT_ID \
  --auth0-audience   https://relay.example.com \
  --name             workshop-box

udha-agent login     # prints a URL
udha-agent status
```

The box has no browser, and the callback listener binds `127.0.0.1:8789` on the
box — so forward that port from the machine whose browser you will use:

```bash
ssh -L 8789:localhost:8789 your-box
udha-agent login          # then open the printed URL locally
```

Restart the service afterwards if it was already running — it re-reads the
credential file within 15 s on its own, but a restart is instant:

```bash
systemctl --user restart udha-agent
```

### The iOS app

Same four values in its settings. Only this client registers a device token,
and only for the `APNS_BUNDLE_ID` you configured — a bundle id mismatch means
pushes are accepted by the relay and dropped by Apple.

---

## 5. Verify

### The health route

```bash
curl -fsS https://relay.example.com/health
```

```json
{"status":"ok","version":"2.0.0","uptimeSeconds":41,"authMode":"auth0",
 "push":"disabled","hosts":1,"clients":2}
```

`hosts` and `clients` are live counts across every account, which makes this
the fastest way to answer "did my Mac actually connect?". The route answers
even when Auth0 is unreachable — a relay that is up but cannot verify tokens is
a state you want to be able to see.

### A raw WebSocket

With [websocat](https://github.com/vi/websocat):

```bash
# 401 — a garbage token is rejected at the HTTP upgrade, before any frame.
websocat "wss://relay.example.com/client?token=garbage"
#   error: ... 401 Unauthorized

# 404 — only /home and /client exist.
websocat "wss://relay.example.com/nope?token=x"
#   error: ... 404 Not Found
```

With a real token (copy the `access_token` from an Auth0 test request, or from
**APIs → your API → Test**):

```bash
websocat "wss://relay.example.com/client?token=$TOKEN"
# the relay speaks first:
{"type":"paired_instances","instances":[{"instanceId":"workshop-box-a91f3c","name":"workshop-box","isOnline":true,"paired":true,...}]}
{"type":"home_connected"}
```

`wscat -c "wss://relay.example.com/client?token=$TOKEN"` does the same.

Seeing your machine in that `instances` array with `isOnline: true` is proof
the whole chain works: the host signed in, dialled out, and the relay matched
it to your account.

### Log lines to expect

A host connecting:

```
[...] Auth successful for user: you@example.com
[...] Home server connected: 10.0.0.7 (user: you@example.com, instance: workshop-box-a91f3c)
```

A client connecting and pairing:

```
[...] Client connected: 10.0.0.9 (user: you@example.com, clientId: 6abe8f554cbbea54)
[...] Sent 1 paired instances to client 6abe8f554cbbea54
[...] Pairing request for instance workshop-box-a91f3c
[...] Pairing successful for instance workshop-box-a91f3c
[...] Client 6abe8f554cbbea54 subscribed to instance workshop-box-a91f3c
```

A rejected token:

```
[...] [SECURITY] INVALID_TOKEN from 10.0.0.9 - path=/client, error=jwt audience invalid. expected: https://relay.example.com
```

### The test suite

```bash
cd relay
npm ci
npm test
```

Three files (`tests/attention.test.js`, `tests/relay-routing.test.js`,
`tests/relay-coldstart.test.js`): the handler/APNs unit test runs `server.js`
in a sandbox with the network stubbed; the two integration tests spawn the real
`server.js` on a spare port with `AUTH_MODE=insecure-dev` and drive it over
real WebSockets (client-id stamping, per-client targeting, and the cold-start
pairing case where a client connects after a host it has never seen).

---

## Troubleshooting

### The bridge says "disconnected" after a while

**Almost always: Allow Offline Access is off on the Auth0 API.**

Auth0 does not error when an app asks for `offline_access` against an API that
does not allow it — it quietly issues an access token and no refresh token.
Sign-in works, the bridge connects, and everything looks correct until the
access token expires (a day by default). Then the client has nothing to renew
with, the socket closes, and the status goes to disconnected with no
explanation, on a machine that may be in another country.

Fix: **Applications → APIs → your API → Settings → Allow Offline Access → on**,
then sign in again on every machine (the existing session has no refresh token
to gain retroactively). Check **Advanced Settings → Grant Types → Refresh
Token** on the Native application too — unticking it produces the identical
symptom.

Confirm from the box with `udha-agent status`, which reports whether it holds
cached tokens.

### Sign-in never returns / the browser hangs on localhost:8789

The callback URL is not registered. **Applications → your app → Settings →
Allowed Callback URLs** must contain exactly `http://localhost:8789/callback`
(`http`, not `https`; `localhost`, not `127.0.0.1`). On a remote box, also make
sure you forwarded the port: `ssh -L 8789:localhost:8789 your-box`. The
listener binds `127.0.0.1` on the machine running `udha-agent login`, and it
gives up after five minutes.

### 401 at the upgrade

Read the `[SECURITY] INVALID_TOKEN` line — it carries the reason.

- `jwt audience invalid. expected: X` — `AUTH0_AUDIENCE` on the relay and the
  `audience` in the app are different strings. They must match byte for byte,
  trailing slash included.
- `jwt issuer invalid` — an Auth0 custom domain. Set `AUTH0_ISSUER` (and
  probably `AUTH0_JWKS_URI`) to match the tokens.
- `jwt expired` — clock skew on the relay host, or a client that is not
  refreshing (see the first entry).
- `jwt malformed` — not a JWT at all; usually an ID token or an API key pasted
  into the wrong field.

### A machine keeps disconnecting with code 4002

`4002` means *replaced by a new connection*: two processes are connecting as
the same `instanceId` and each one kicks the other off. Usually the desktop
app running twice, or an agent started both by systemd and by hand. The client
treats 4002 as final and stops retrying, by design.

### The host is online but the client's list is empty

A client learns instance ids from `paired_instances` (sent once, at connect)
and from the `instance_online` broadcast (sent once, when the host connects).
If the client connected during a window where neither happened, reconnect the
client. Note that the relay deliberately advertises *online but not yet paired*
hosts in that list — without that a fresh account could never pair at all.

### Pushes never arrive on the phone

In order of likelihood: `APNS_PRODUCTION` does not match how the app was
installed (an Xcode build needs `false`; TestFlight needs `true`, and a token
from one environment is rejected by the other); `APNS_BUNDLE_ID` is not the
bundle id of the build that registered; the key is not enabled for APNs in the
developer portal. The relay logs `APNs error: status <n>` per attempt — 403 is
a bad key/team, 400 with `BadDeviceToken` is the environment mismatch.

Also expected, not a bug: a push is suppressed while the phone is foregrounded
on that exact session (`attention_presence`, `ATTENTION_PRESENCE_TTL_MS`).

### Pairings vanish after a redeploy

`DATA_DIR` is not on a volume. docker-compose mounts `relay-data:/data`; if you
run the image by hand, pass `-v udha-relay-data:/data`.

---

## Protocol, in one page

Useful if you are writing another client or debugging a frame in the logs.

**Connect.** `wss://<relay>/home?token=<JWT>&instanceId=<ID>` for a machine
being supervised, `wss://<relay>/client?token=<JWT>` for a thing looking at it.
The token is an Auth0 *access* token for your API. Both sides send
`{"type":"ping"}` and expect `{"type":"pong"}`; the relay also drives
protocol-level pings every `PING_INTERVAL_MS`.

**Relay → client, unwrapped:**

| Type | When |
| --- | --- |
| `paired_instances` | once, at connect — `instances[]` with `instanceId`, `name`, `isOnline`, `paired`, `pairedAt`, `lastSeen` |
| `instance_online` / `instance_offline` | a host connected or dropped (broadcast to every client of that account) |
| `home_connected` / `home_disconnected` | legacy summary at connect; current clients ignore it |
| `pair_success` / `pair_failed` | answer to `pair_request` |
| `active_instance_set` / `instances_subscribed` | acks |
| `device_registered` | ack for `register_device` |
| `error` | `data` says why; e.g. the target instance is not connected |

**Client → relay:** `pair_request` (`instanceId`, `pairingToken`),
`unpair_request`, `set_active_instance` (`instanceId`; `""` unsubscribes),
`subscribe_instances` (`instanceIds[]`, for watching several machines at once),
`register_device` (`deviceToken`, iOS), `attention_presence`
(`sessionId`, `instanceId` — suppresses pushes for what you are looking at),
and `relay` (`instanceId`, `payload`) for everything else.

**Relay → host:** `validate_pairing` (`requestId`, `pairingToken`) and any
`relay` envelope from a client, stamped with the originating `clientId`.

**Host → relay:** `pairing_valid` (`requestId`, `valid`, `metadata`) and
`relay` (`payload`, optional `toClientId` to answer one device rather than
broadcasting to all of that account's subscribed clients).

The `payload` inside a `relay` envelope is the application protocol between
the app and the machine (`hello`, `sessions_full`, `send_input`,
`terminal_frame`, …). The relay does not parse it, with one exception:
`payload.type === "notify"` also fires a push, which is how a backgrounded
phone hears that a session is waiting on a human.

**Routing rules, in full:** a message only ever reaches a connection
authenticated as the same Auth0 `sub`; a client only receives traffic from
instances it has subscribed to; `toClientId` narrows a host's reply to one
client; and a host→client message that reaches nobody, carrying an `output`
payload, falls back to a push.

---

## License

Covered by the license of the repository it is vendored into. This is a copy of
the relay Udha's own fleet runs, kept here so the system can be run end to end
by someone who is not us.
