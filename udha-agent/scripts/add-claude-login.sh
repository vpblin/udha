#!/usr/bin/env bash
# Add another Claude login to a tree's pool on this box.
#
#   add-claude-login.sh <base config dir> <suffix> [email]
#   add-claude-login.sh ~/.claude-work work-2 dev2@example.com
#
# Creates ~/.claude-<suffix> as a second login that behaves exactly like the
# base one — same settings, skills, plugins, agents, CLAUDE.md, prompt history
# and (via one shared `projects/`) the same transcripts and auto-memory — then
# runs `claude auth login` for it and records it as an alternate of the base
# dir in Udha's config.json. Sign-in is interactive: it prints a URL, open it
# anywhere, paste the code back. Run it over SSH.
set -euo pipefail
BASE="${1:?base config dir, e.g. ~/.claude-work}"
SUFFIX="${2:?suffix for the new dir, e.g. work-2}"
EMAIL="${3:-}"
BASE="${BASE/#\~/$HOME}"
NEW="$HOME/.claude-$SUFFIX"
CONFIG="${UDHA_CONFIG:-$HOME/.local/share/Udha.AI/config.json}"

[[ -d "$BASE" ]] || { echo "✗ $BASE does not exist"; exit 1; }
[[ -f "$BASE/.credentials.json" ]] || { echo "✗ $BASE is not signed in (no .credentials.json)"; exit 1; }
command -v claude >/dev/null || { echo "✗ claude is not on PATH"; exit 1; }

mkdir -p "$NEW"
# Everything that makes the login *behave* the same is shared, not copied, so a
# later edit in one place is an edit everywhere. `projects` too: that is where
# transcripts and per-project auto-memory live, and a conversation moving
# between logins must find both under either dir.
for item in projects settings.json skills plugins agents commands CLAUDE.md keybindings.json history.jsonl; do
  if [[ -e "$BASE/$item" && ! -e "$NEW/$item" ]]; then
    ln -s "$BASE/$item" "$NEW/$item"
    echo "  linked $item"
  fi
done
# Onboarding and per-folder trust come from the base; the account block is
# what login writes, so it must not be carried over.
if [[ ! -f "$NEW/.claude.json" ]]; then
  python3 - "$BASE/.claude.json" "$NEW/.claude.json" <<'PY'
import json, sys
src, dst = sys.argv[1], sys.argv[2]
d = json.load(open(src))
for k in ("oauthAccount", "userID", "cachedExtraUsageDisabledReason", "hasAvailableSubscription", "subscriptionNoticeCount"):
    d.pop(k, None)
d["hasCompletedOnboarding"] = True
json.dump(d, open(dst, "w"))
print(f"  seeded .claude.json ({len(d.get('projects', {}))} trusted folders)")
PY
  chmod 600 "$NEW/.claude.json"
fi

echo "▶ signing $NEW in — open the URL it prints on any device"
if [[ -n "$EMAIL" ]]; then
  CLAUDE_CONFIG_DIR="$NEW" claude auth login --email "$EMAIL"
else
  CLAUDE_CONFIG_DIR="$NEW" claude auth login
fi
CLAUDE_CONFIG_DIR="$NEW" claude auth status | python3 -c 'import json,sys; d=json.load(sys.stdin); print("  signed in as", d.get("email"), "·", d.get("orgName"))'

# Record it as an alternate of the base dir.
if [[ -f "$CONFIG" ]]; then
  python3 - "$CONFIG" "$BASE" "$NEW" <<'PY'
import json, os, sys
path, base, new = sys.argv[1], sys.argv[2], sys.argv[3]
home = os.path.expanduser("~")
def tilde(p): return "~" + p[len(home):] if p.startswith(home) else p
def full(p): return os.path.expanduser(p)
cfg = json.load(open(path))
accounts = cfg.setdefault("claudeAccounts", [])
hit = [a for a in accounts if full(a.get("configDir", "")) == base]
if not hit:
    print(f"  ✗ no claudeAccounts entry has configDir {tilde(base)} — add one, then list {tilde(new)} under its alternates")
    sys.exit(0)
alts = hit[0].setdefault("alternates", [])
if tilde(new) not in alts and new not in alts:
    alts.append(tilde(new))
    json.dump(cfg, open(path, "w"), indent=2)
    print(f"  {tilde(new)} added to the pool of {hit[0]['pathPrefix']} → {[tilde(full(hit[0]['configDir']))] + alts}")
else:
    print(f"  {tilde(new)} was already in the pool")
PY
  echo "▶ restart the agent so it reads the new pool:  systemctl --user restart udha-agent"
else
  echo "  (no Udha config at $CONFIG — add ~/.claude-$SUFFIX to claudeAccounts[].alternates by hand)"
fi
