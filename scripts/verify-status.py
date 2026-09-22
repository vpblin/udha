#!/usr/bin/env python3
"""Ground truth for Udha's session status, read straight from tmux.

Mirrors Sessions/ClaudePaneReader.swift so the app's overlay can be diffed
against an independent reading of the same panes:

    ./scripts/verify-status.py            # every udha-* session
    ./scripts/verify-status.py udha-gameu-4069bd54

One difference is unavoidable: the app watches the streaming -> quiet edge
across successive 2s polls to decide a turn has ended, which a one-shot script
can't do. Here "Ready" is inferred from the spinner's past-tense resting line
still being on screen, so a session whose spinner has scrolled away reads as
"Idle" from this script while the app correctly says "Ready".
"""
import re
import subprocess
import sys

TMUX = "/opt/homebrew/bin/tmux"

ANSI = re.compile(r"\x1b\[[0-9;?]*[a-zA-Z]")
DIM = "\x1b[2m"

# Any of the three markers Claude paints in its footer. A session in default
# "ask" mode shows only "? for shortcuts", so anchoring on one marker would
# misread it as a non-Claude pane.
FOOTER = re.compile(r"shift\s*\+?\s*tab to cycle|\?\s*for shortcuts|esc to interrupt", re.I)
STREAMING = re.compile(r"esc to interrupt", re.I)
PLAN = re.compile(r"⏸\s*plan mode on", re.I)
DIALOG = re.compile(r"esc to cancel|enter to confirm", re.I)
# Claude's full-pane overlays (/btw panel, transcript scroller, fork picker)
# replace the footer, hiding every signal.
OVERLAY = re.compile(r"esc to close|to scroll ·|c to copy", re.I)
SPIN_ACTIVE = re.compile(r"^\s*[✻✳✽✢✶✷✸✹✺∗*·]\s+([A-Za-zÀ-ÿ]+)…\s*\((.+)\)\s*$")
SPIN_DONE = re.compile(r"^\s*[✻✳✽✢✶✷✸✹✺∗*·]\s+([A-Za-zÀ-ÿ]+)\s+for\s+(\d[\dhms\s]*)\s*$")
TOOL = re.compile(r"^\s*[⏺●]\s+([A-Z][A-Za-z_]*)\((.{0,120})\)")
SUBAGENT = re.compile(r"^\s*[◯◉]\s+(\S+)\s\s+\S")
RULE = re.compile(r"^\s*─{10,}\s*$")


def sessions():
    out = subprocess.run([TMUX, "ls", "-F", "#{session_name}"], capture_output=True)
    return [s for s in out.stdout.decode().split("\n") if s.strip()]


def read(name):
    raw = subprocess.run(
        [TMUX, "capture-pane", "-p", "-e", "-t", name], capture_output=True
    ).stdout.decode("utf-8", "replace")
    lines = raw.split("\n")
    plain = [ANSI.sub("", l).replace("\r", "") for l in lines]

    footer = None
    for i, l in enumerate(plain):
        if FOOTER.search(l):
            footer = i
    if footer is None:
        # Last few non-blank lines: capture-pane returns the whole grid, so a
        # fixed tail window can land entirely in blank padding.
        tail = [l for l in plain if l.strip()][-6:]
        if any(OVERLAY.search(l) for l in tail):
            return {"tui": True, "obscured": True}
        return {"tui": False}

    r = {
        "tui": True,
        "streaming": bool(STREAMING.search(plain[footer])),
        "plan": bool(PLAN.search(plain[footer])),
        "dialog": any(DIALOG.search(l) for l in plain[max(0, footer - 3): footer + 2]),
        "subagents": sum(1 for l in plain[footer:] if SUBAGENT.match(l)),
    }

    # Input box = band between the last two rules above the footer. A dim ❯ line
    # is Claude's ghost suggestion; only a bright one is text you typed.
    rules = [i for i in range(footer - 1, max(-1, footer - 13), -1) if RULE.match(plain[i])]
    r["draft"] = None
    if len(rules) >= 2:
        lower, upper = rules[0], rules[1]
        for idx in range(upper + 1, lower):
            if "❯" in plain[idx] and DIM not in lines[idx]:
                text = plain[idx].split("❯", 1)[1].strip()
                if text:
                    r["draft"] = text
                    break

    for i in range(footer - 1, max(-1, footer - 17), -1):
        m = SPIN_ACTIVE.match(plain[i])
        if m:
            r["spin"] = ("active", m.group(1), m.group(2))
            break
        m = SPIN_DONE.match(plain[i])
        if m:
            r["spin"] = ("done", m.group(1), m.group(2).strip())
            break

    for i in range(footer - 1, -1, -1):
        m = TOOL.match(plain[i])
        if m:
            r["tool"] = (m.group(1), m.group(2))
            break
    return r


def phase(r):
    if not r["tui"]:
        return "NON-CLAUDE", ""
    if r.get("obscured"):
        # The app holds its previous phase here; this script has no history.
        return "(overlay open)", "chrome hidden — app holds last phase"
    spin = r.get("spin")
    if r["dialog"]:
        return "NEEDS APPROVAL", ""
    if r["streaming"]:
        detail = spin[2] if spin and spin[0] == "active" else ""
        if r["plan"]:
            return "PLANNING", detail
        if spin and spin[0] == "active" and "thinking" in spin[2].lower():
            return "THINKING", detail
        if r.get("tool"):
            return "WORKING", f"{r['tool'][0]}({r['tool'][1][:38]})"
        return "THINKING", detail
    if spin and spin[0] == "done":
        return "READY", f"done in {spin[2]}"
    return "IDLE", ""


def main():
    names = sys.argv[1:] or [s for s in sessions() if s.startswith("udha-")]
    for name in names:
        try:
            r = read(name)
            p, detail = phase(r)
            extra = ""
            if r.get("subagents"):
                extra += f"  +{r['subagents']}sub"
            if r.get("draft"):
                extra += f"  DRAFT:{r['draft'][:28]!r}"
            print(f"{name[:36]:38} {p:15} {detail[:46]}{extra}")
        except Exception as exc:  # noqa: BLE001 - diagnostic script
            print(f"{name[:36]:38} ERROR {exc}")


if __name__ == "__main__":
    main()
