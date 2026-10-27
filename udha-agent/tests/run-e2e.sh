#!/usr/bin/env bash
# Runs udha-agent against the relay's mock server with a fake token and drives it
# with e2e-mock.js. Restores the real config/secrets afterwards. Linux only.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export PATH="$HOME/.local/bin:$PATH"
export NVM_DIR="$HOME/.nvm"; [ -s "$NVM_DIR/nvm.sh" ] && . "$NVM_DIR/nvm.sh" >/dev/null
AGENT="${AGENT:-$HOME/.local/bin/udha-agent}"
# The relay repo's test-harness directory (holds mock-relay.js; ../relay-server has the `ws` module).
HARNESS="${HARNESS:?set HARNESS to the relay test-harness directory}"
export NODE_PATH="$HARNESS/../relay-server/node_modules${NODE_PATH:+:$NODE_PATH}"
PORT="${PORT:-8090}"
CONFIG="$HOME/.local/share/Udha.AI/config.json"
SECRETS="$HOME/.config/udha/secrets.json"
LOG=/tmp/udha-agent-e2e; mkdir -p "$LOG"

[ -f "$HARNESS/../relay-server/node_modules/ws/package.json" ] || (cd "$HARNESS/../relay-server" && npm install --silent ws >/dev/null)

cleanup() {
  set +e
  [ -n "${AGENT_PID:-}" ] && kill "$AGENT_PID" 2>/dev/null
  [ -n "${RELAY_PID:-}" ] && kill "$RELAY_PID" 2>/dev/null
  [ -f "$CONFIG.e2e-bak" ] && mv "$CONFIG.e2e-bak" "$CONFIG"
  if [ -f "$SECRETS.e2e-bak" ]; then mv "$SECRETS.e2e-bak" "$SECRETS"; else rm -f "$SECRETS"; fi
  tmux kill-session -t "$(tmux ls -F '#S' 2>/dev/null | grep '^udha-e2e-agent' | head -1)" 2>/dev/null
}
trap cleanup EXIT

mkdir -p "$(dirname "$CONFIG")" "$(dirname "$SECRETS")"
[ -f "$CONFIG" ] && cp "$CONFIG" "$CONFIG.e2e-bak"
[ -f "$SECRETS" ] && cp "$SECRETS" "$SECRETS.e2e-bak"
python3 - "$CONFIG" "$PORT" <<'PY'
import json, sys, os
p, port = sys.argv[1], sys.argv[2]
d = json.load(open(p)) if os.path.exists(p) else {}
mb = d.setdefault("mobileBridge", {}); mb["enabled"] = True; mb["relayURL"] = f"ws://localhost:{port}"
d["verboseLogging"] = True
json.dump(d, open(p, "w"), indent=2)
PY
python3 - "$SECRETS" <<'PY'
import json, sys, time
p = sys.argv[1]
json.dump({"mobile_bridge_access_token": "fake.e2e.token",
           "mobile_bridge_expires_at": str(time.time() + 86400)}, open(p, "w"))
PY

PORT=$PORT node "$HARNESS/mock-relay.js" > "$LOG/relay.log" 2>&1 & RELAY_PID=$!
sleep 1
"$AGENT" run > "$LOG/agent.log" 2>&1 & AGENT_PID=$!
sleep 3
kill -0 "$AGENT_PID" 2>/dev/null || { echo "agent died:"; cat "$LOG/agent.log"; exit 1; }

RELAY="ws://localhost:$PORT" node "$HERE/e2e-mock.js"
rc=$?
echo "--- agent log tail:"; grep -vE 'DEBUG' "$HOME/.local/state/udha/udha.log" | tail -15
exit $rc
