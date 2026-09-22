#!/usr/bin/env bash
#
# audit.sh — refuse to publish anything that names somebody's infrastructure.
#
# Scans every file that would ship (tracked + untracked-but-not-ignored) for
# private addresses, tenant and account ids, home directories, and the shapes
# secrets come in. Prints `file:line: match` for every hit and exits 1 if there
# was one.
#
# Two things it deliberately does NOT do:
#   * guess. A default that points at a service somebody runs is a finding even
#     when it is "only" in a comment — a stranger cloning this repo must not end
#     up talking to a machine that is not theirs.
#   * scan only contents. A path can carry a name too (`~/.claude-acme/`,
#     `xcuserdata/alice.xcuserdatad/`), so the file list itself is scanned with
#     the same patterns.
#
# Usage:
#   scripts/release/audit.sh [DIR]      # DIR defaults to the repo root
#
# The patterns below are **generic**: shapes, not names. Your own machine names,
# client names, employer, tenant ids and so on belong in
#
#     scripts/release/audit-private.txt      (git-ignored, one regex per line)
#
# which is read from beside this script if it exists — a list of the exact
# strings you are scrubbing is itself a disclosure, so it must never be the
# thing you publish. Override its location with UDHA_AUDIT_PRIVATE=/path.
#
# False positives go in scripts/release/audit-allow.txt, one extended regex per
# line, matched against the whole `path:line:text` output line. Keep that file
# short and keep a reason beside each entry: it is the one place where "this
# string is fine" is asserted rather than proven.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ROOT="${1:-}"
if [[ -z "$ROOT" ]]; then
  ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
fi
cd "$ROOT"

# Both lists live beside the script, not under the tree being scanned: the
# whole point is to audit an exported copy with the rules you keep here.
ALLOW="$SCRIPT_DIR/audit-allow.txt"
PRIVATE="${UDHA_AUDIT_PRIVATE:-$SCRIPT_DIR/audit-private.txt}"

RG="$(command -v rg || true)"

# --- what must never ship -----------------------------------------------------
# Every line is an extended regex, matched case-sensitively.
PATTERNS=$(cat <<'EOF'
sk-ant-[A-Za-z0-9_-]{8,}
xoxb-[0-9]{6,}
xapp-[0-9]
ghp_[A-Za-z0-9]{20,}
github_pat_[A-Za-z0-9_]{20,}
AKIA[0-9A-Z]{16}
ASIA[0-9A-Z]{16}
AIza[0-9A-Za-z_-]{20,}
-----BEGIN [A-Z ]*PRIVATE KEY-----
eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.
AuthKey_[A-Z0-9]{10}
dev-[a-z0-9]{16,}\.(us|eu|au|jp)\.auth0\.com
[0-9a-z]{8,12}\.execute-api\.[a-z0-9-]+\.amazonaws\.com
[a-z0-9][a-z0-9-]*\.ts\.net
100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}
192\.168\.[0-9]{1,3}\.[0-9]{1,3}
172\.(1[6-9]|2[0-9]|3[01])\.[0-9]{1,3}\.[0-9]{1,3}
(^|[^0-9.])10\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}([^0-9.]|$)
/Users/[a-z]
/home/[a-z]
xcuserdata
\.p12($|[^a-z])
id_(rsa|ed25519|ecdsa)
EOF
)

PATFILE="$(mktemp -t udha-audit-pat)"
LIST="$(mktemp -t udha-audit-files)"
RAW="$(mktemp -t udha-audit-raw)"
trap 'rm -f "$PATFILE" "$PATFILE.allow" "$LIST" "$LIST.filtered" "$SELF" "$RAW" "$RAW.kept"' EXIT
SELF=
printf '%s\n' "$PATTERNS" > "$PATFILE"

PRIVATE_COUNT=0
if [[ -f "$PRIVATE" ]]; then
  grep -Ev '^\s*(#|$)' "$PRIVATE" >> "$PATFILE" || true
  PRIVATE_COUNT=$(grep -cEv '^\s*(#|$)' "$PRIVATE" || true)
fi

# --- what would ship ----------------------------------------------------------
# In a git tree: the index plus untracked files git would not ignore, minus the
# per-machine files that never leave this disk. Outside one (an already-exported
# orphan copy being re-checked): every file.
if git -C "$ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  { git -C "$ROOT" ls-files --cached --exclude-standard
    git -C "$ROOT" ls-files --others --exclude-standard; } | sort -u > "$LIST"
else
  find . -type f -not -path './.git/*' | sed 's|^\./||' | sort -u > "$LIST"
fi

# Excluded from the scan because they are excluded from the publish, and only
# for that reason. Keep this list identical to publish-public.sh's.
grep -Ev '^(CLAUDE\.md|Local\.xcconfig|\.claude/|graphify-out/|[^/]*\.png$)' "$LIST" \
  | grep -v 'xcuserdata/' \
  | grep -v '/node_modules/' \
  | grep -v '^node_modules/' \
  > "$LIST.filtered" || true
# An index entry whose file is gone from the working tree is not published, so
# it is not scanned either.
while IFS= read -r f; do [[ -e "$f" ]] && printf '%s\n' "$f"; done < "$LIST.filtered" > "$LIST"
rm -f "$LIST.filtered"

FILE_COUNT=$(wc -l < "$LIST" | tr -d ' ')
echo "audit: scanning $FILE_COUNT files under $ROOT"
if [[ "$PRIVATE_COUNT" -gt 0 ]]; then
  echo "audit: + $PRIVATE_COUNT private pattern(s) from $PRIVATE"
else
  echo "audit: no private pattern file at $PRIVATE — generic patterns only"
fi

: > "$RAW"

# The audit's own files are patterns about patterns: this script's list, and
# the allowlist's quoted literals. Grepping them finds nothing but itself, and
# every "hit" would be its own excuse — so they are dropped from the *content*
# scan. They stay in the file count and in the path scan, and they are the one
# pair of files a reviewer should read by eye rather than trust a grep on.
SELF="$(mktemp -t udha-audit-self)"
grep -v -E '^scripts/release/audit(-allow|-private)?\.(sh|txt)$' "$LIST" > "$SELF" || true

scan_contents() {
  if [[ -n "$RG" ]]; then
    # --no-ignore so an ignore file inside the tree cannot hide a file from the
    # audit; the file list above already decides what is in scope.
    tr '\n' '\0' < "$SELF" \
      | xargs -0 "$RG" --no-ignore --hidden --no-messages -n -f "$PATFILE" -- 2>/dev/null \
      >> "$RAW" || true
  else
    while IFS= read -r f; do
      [[ -f "$f" ]] || continue
      grep -n -E -f "$PATFILE" -- "$f" 2>/dev/null | sed "s|^|$f:|" >> "$RAW" || true
    done < "$SELF"
  fi
}

scan_paths() {
  grep -n -E -f "$PATFILE" "$LIST" 2>/dev/null \
    | sed 's|^|<path>:|' >> "$RAW" || true
}

scan_contents
scan_paths

# --- allowlist ----------------------------------------------------------------
if [[ -s "$RAW" && -f "$ALLOW" ]]; then
  # Comments and blank lines are not patterns.
  if grep -Ev '^\s*(#|$)' "$ALLOW" > "$PATFILE.allow" 2>/dev/null && [[ -s "$PATFILE.allow" ]]; then
    grep -vE -f "$PATFILE.allow" "$RAW" > "$RAW.kept" || true
    mv "$RAW.kept" "$RAW"
  fi
  rm -f "$PATFILE.allow"
fi

HITS=$(wc -l < "$RAW" | tr -d ' ')
if [[ "$HITS" -gt 0 ]]; then
  echo
  echo "audit: FAILED — $HITS line(s) name infrastructure or look like a secret:"
  echo
  cat "$RAW"
  echo
  echo "Fix each one, or — only if it is genuinely a false positive — add a"
  echo "regex with a reason to scripts/release/audit-allow.txt."
  exit 1
fi

echo "audit: clean — no forbidden strings in $FILE_COUNT files."
