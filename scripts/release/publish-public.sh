#!/usr/bin/env bash
#
# publish-public.sh — export this working tree as a fresh, single-commit public
# repository.
#
# The private repo's history is not rewritten and not reused: a squash or a
# filter still leaves the old objects reachable from anything that ever fetched
# them, and this tree's history contains machine names and, once, credentials.
# So the public repo starts from nothing — one orphan commit containing the
# files as they are right now, authored by a neutral identity.
#
# What it copies: `git ls-files --cached --others --exclude-standard`, i.e. the
# index plus untracked files .gitignore does not cover, minus the per-machine
# files below. It never copies .git, so nothing of the old history travels.
#
# Excluded, always:
#   CLAUDE.md          working notes: machine names, client names, addresses
#   Local.xcconfig     this Mac's bundle id and signing team
#   .claude/           per-machine Claude Code settings
#   xcuserdata/        Xcode's per-user state, named after the account
#   graphify-out/      generated analysis output
#   *.png at the root  stray renders
#
# Usage:
#   scripts/release/publish-public.sh                      # dry run (default)
#   scripts/release/publish-public.sh --out DIR            # dry run into DIR
#   scripts/release/publish-public.sh --push <git-url> [branch]
#   scripts/release/publish-public.sh --push <git-url> main --i-know   # override the private-origin guard
#
# The audit runs against the exported copy, not against this tree, and a hit
# aborts before anything is pushed. This checkout's refs are never touched:
# the commit is made in a scratch clone and pushed from there.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO"

AUTHOR_NAME="Udha"
AUTHOR_EMAIL="udha@users.noreply.github.com"
COMMIT_MESSAGE="Udha desktop — initial public release"
# Pushing here would put the scrubbed tree back on top of the private repo.
PRIVATE_ORIGIN_RE='vpblin/udha-desktop'

PUSH_URL=""
BRANCH="main"
I_KNOW=0
OUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --push)
      PUSH_URL="${2:-}"
      if [[ -z "$PUSH_URL" ]]; then echo "publish: --push needs a git URL" >&2; exit 2; fi
      shift 2
      # An optional branch may follow the URL, but --flags must not be eaten.
      if [[ $# -gt 0 && "$1" != --* ]]; then BRANCH="$1"; shift; fi
      ;;
    --i-know) I_KNOW=1; shift ;;
    --out)
      OUT_DIR="${2:-}"
      if [[ -z "$OUT_DIR" ]]; then echo "publish: --out needs a directory" >&2; exit 2; fi
      shift 2
      ;;
    -h|--help) sed -n '2,32p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "publish: unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ -n "$PUSH_URL" && "$PUSH_URL" =~ $PRIVATE_ORIGIN_RE && "$I_KNOW" -ne 1 ]]; then
  cat >&2 <<EOF
publish: refusing to push to what looks like the PRIVATE origin:
  $PUSH_URL

That repository holds the history this export exists to leave behind. If you
really mean it, re-run with --i-know.
EOF
  exit 3
fi

command -v rsync >/dev/null || { echo "publish: rsync is required" >&2; exit 2; }

# The scratch directory is deliberately never deleted: a dry run exists to be
# read afterwards, and after a push it is the record of exactly what went out.
# The template is spelled out rather than using `mktemp -t`, which on macOS
# ignores TMPDIR and always lands in the per-user darwin temp directory.
BASE_DIR="${OUT_DIR:-${TMPDIR:-/tmp}}"
mkdir -p "$BASE_DIR"
SCRATCH="$(mktemp -d "${BASE_DIR%/}/udha-public.XXXXXXXX")"

echo "publish: exporting $REPO"
echo "publish: scratch  $SCRATCH"

# --- the file list ------------------------------------------------------------
LIST="$SCRATCH/.files"
{ git ls-files --cached --exclude-standard
  git ls-files --others --exclude-standard; } | sort -u \
  | grep -Ev '^(CLAUDE\.md|Local\.xcconfig|[^/]*\.png)$' \
  | grep -Ev '^(\.claude|graphify-out)/' \
  | grep -v 'xcuserdata/' \
  | grep -v '^node_modules/' \
  | grep -v '/node_modules/' \
  > "$LIST.all"

# The index can name a file the working tree no longer has (staged, then
# deleted, or deleted but not yet staged). What is published is the tree as it
# stands, so drop anything that is not actually there — rsync would abort on it.
while IFS= read -r f; do [[ -e "$f" ]] && printf '%s\n' "$f"; done < "$LIST.all" > "$LIST"
MISSING=$(( $(wc -l < "$LIST.all") - $(wc -l < "$LIST") ))
[[ "$MISSING" -gt 0 ]] && echo "publish: skipped $MISSING index entr(y|ies) missing from the working tree"
rm -f "$LIST.all"

FILE_COUNT=$(wc -l < "$LIST" | tr -d ' ')
echo "publish: $FILE_COUNT files"

# --- copy ---------------------------------------------------------------------
TREE="$SCRATCH/repo"
mkdir -p "$TREE"
# Symlinks are copied as symlinks, not dereferenced: udha-agent/Sources/.../
# Shared/* are relative links into Udha.AIDesktop/, and that is the point of
# them — one pane reader, one protocol, never a second copy to drift. They are
# relative and their targets are inside the export, so they resolve in a fresh
# clone. --files-from keeps the list authoritative.
rsync -a --files-from="$LIST" "$REPO/" "$TREE/"

# --- history ------------------------------------------------------------------
git -C "$TREE" init -q -b "$BRANCH"
git -C "$TREE" add -A
GIT_AUTHOR_NAME="$AUTHOR_NAME" GIT_AUTHOR_EMAIL="$AUTHOR_EMAIL" \
GIT_COMMITTER_NAME="$AUTHOR_NAME" GIT_COMMITTER_EMAIL="$AUTHOR_EMAIL" \
  git -C "$TREE" commit -q -m "$COMMIT_MESSAGE"

# --- audit the thing that would actually be published --------------------------
echo
if ! "$REPO/scripts/release/audit.sh" "$TREE"; then
  echo >&2
  echo "publish: ABORTED — the exported tree did not pass the audit." >&2
  echo "publish: the failing copy is at $TREE" >&2
  exit 1
fi

echo
echo "publish: one commit, $(git -C "$TREE" rev-list --count HEAD) total"
git -C "$TREE" log --format='commit %H%nAuthor: %an <%ae>%nDate:   %ad%n%n    %s%n' -1
git -C "$TREE" log --stat --oneline -1 | tail -n 25
echo "publish: (full stat: git -C $TREE log --stat)"

if [[ -z "$PUSH_URL" ]]; then
  cat <<EOF

publish: DRY RUN — nothing was pushed.
publish: inspect it:   cd $TREE && git log --stat
publish: publish it:   $0 --push <git-url> [branch]
EOF
  exit 0
fi

echo
echo "publish: pushing $BRANCH to $PUSH_URL"
git -C "$TREE" remote add public "$PUSH_URL"
git -C "$TREE" push --force public "HEAD:refs/heads/$BRANCH"
echo "publish: pushed. The scratch copy is at $TREE"
