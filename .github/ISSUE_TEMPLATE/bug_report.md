---
name: Bug report
about: Something does not behave the way the docs say it should
labels: bug
---

**What happened**

**What you expected**

**Steps to reproduce**

**Environment**
- macOS version and chip:
- Udha built from commit:
- `tmux --version`:
- Assistant and version (`claude --version`, `codex --version`, `qwen --version`):
- Remote machine involved? If so, `udha-agent status` output (redact the instance id if you like):

**Logs**
Relevant lines from `~/Library/Logs/Udha.AI/udha.log` — turn on Settings → Advanced → verbose logging first if
the problem is in classification. On a box: `~/.local/state/udha/udha.log`.

**If this is a session showing the wrong state**
Paste the pane the reader was looking at:

```
tmux capture-pane -p -t <session name>
```

Please scrub paths, hostnames and anything else you would not publish.
