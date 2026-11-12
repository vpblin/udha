// Session status, decided the way the mac app decides it: from Claude Code's
// own hook + statusLine feed, never from an LLM. Pure functions only, so the
// rules are testable without a pty (see test/status.test.js).
'use strict';

const path = require('path');

/** A fresh snapshot for a saved session. Mirrors SessionSnapshot (SessionState.swift). */
function newSnapshot(cfg) {
  return {
    id: cfg.id,
    label: cfg.label,
    directory: cfg.directory,
    tool: detectTool(cfg.command),
    command: cfg.command,
    // process lifecycle: stopped (saved, not running) | starting | running | exited
    state: 'stopped',
    // conversation phase: starting | thinking | usingTool | awaitingApproval | awaitingReply | idle | finished
    phase: 'idle',
    phaseDetail: null,
    phaseEnteredAt: Date.now(),
    lastQuestion: null,
    model: null,
    contextPercent: null,
    costCents: null,
    exitCode: null,
    claudeSessionID: cfg.claudeSessionID || null,
    lastOutputAt: 0,
    startedAt: null,
    hidden: !!cfg.hidden,
    folderID: cfg.folderID || null,
    permission: permissionFromArgs(cfg.args),
    branch: cfg.branch || null,
    agentName: cfg.agentName || null,
    loginDir: (cfg.env && cfg.env.CLAUDE_CONFIG_DIR) || null,
    parentSessionID: cfg.parentSessionID || null,
    worktree: !!cfg.worktree,
  };
}

function permissionFromArgs(args = []) {
  if (args.includes('--dangerously-skip-permissions')) return 'bypass';
  const i = args.indexOf('--permission-mode');
  if (i < 0) return 'default';
  return ['plan', 'acceptEdits'].includes(args[i + 1]) ? args[i + 1] : 'default';
}

/** The raw value is the binary (SessionTool in AppConfig.swift). */
function detectTool(command) {
  const base = path.basename(String(command || '')).toLowerCase().replace(/\.(exe|cmd|bat|ps1)$/, '');
  return ['claude', 'codex', 'qwen'].includes(base) ? base : null;
}

function setPhase(snap, phase, detail) {
  if (snap.phase !== phase) {
    snap.phase = phase;
    snap.phaseEnteredAt = Date.now();
  }
  snap.phaseDetail = detail ?? null;
}

/** "Editing main.js", "Running npm test" — the tool phrase is the headline. */
function toolPhrase(name, input) {
  input = input || {};
  const file = input.file_path || input.notebook_path || input.path;
  const base = file ? path.basename(String(file)) : null;
  switch (name) {
    case 'Edit': case 'MultiEdit': case 'Write': case 'NotebookEdit':
      return base ? `Editing ${base}` : 'Editing';
    case 'Read':
      return base ? `Reading ${base}` : 'Reading';
    case 'Bash': case 'PowerShell': {
      const cmd = String(input.command || '').split('\n')[0].trim();
      return cmd ? `Running ${cmd.length > 48 ? cmd.slice(0, 47) + '…' : cmd}` : 'Running a command';
    }
    case 'Grep': case 'Glob':
      return input.pattern ? `Searching ${String(input.pattern).slice(0, 40)}` : 'Searching';
    case 'WebFetch': case 'WebSearch':
      return 'Browsing';
    case 'Task': case 'Agent':
      return input.description ? `Subagent: ${String(input.description).slice(0, 40)}` : 'Running a subagent';
    case 'TodoWrite':
      return 'Planning';
    default:
      return name ? `Using ${name.replace(/^mcp__/, '').replace(/__/g, ' ')}` : 'Working';
  }
}

/**
 * Apply one hook payload to a snapshot. Returns what changed outside the
 * snapshot that the caller has to persist ({ claudeSessionID }) or act on
 * ({ readTranscript }).
 */
function applyHookEvent(snap, payload) {
  const out = {};
  if (!payload || typeof payload !== 'object') return out;
  if (payload.session_id && payload.session_id !== snap.claudeSessionID) {
    // /clear or a resume-fork gives a new id: the one to --resume next time.
    snap.claudeSessionID = payload.session_id;
    out.claudeSessionID = payload.session_id;
  }
  if (payload.transcript_path) out.transcriptPath = payload.transcript_path;

  switch (payload.hook_event_name) {
    case 'SessionStart':
      setPhase(snap, 'idle', null);
      break;
    case 'UserPromptSubmit':
      snap.lastQuestion = null;
      setPhase(snap, 'thinking', null);
      break;
    case 'PreToolUse':
      setPhase(snap, 'usingTool', toolPhrase(payload.tool_name, payload.tool_input));
      break;
    case 'PostToolUse':
    case 'PostToolUseFailure':
    case 'SubagentStop':
      if (snap.phase === 'usingTool' || snap.phase === 'awaitingApproval') setPhase(snap, 'thinking', null);
      break;
    case 'PermissionRequest':
      setPhase(snap, 'awaitingApproval', payload.tool_name ? toolPhrase(payload.tool_name, payload.tool_input) : 'Permission needed');
      break;
    case 'Notification': {
      const msg = String(payload.message || '');
      if (/permission|approve|allow/i.test(msg)) {
        setPhase(snap, 'awaitingApproval', msg);
      } else if (/waiting for your input/i.test(msg)) {
        if (snap.phase !== 'awaitingReply') setPhase(snap, 'awaitingReply', snap.phaseDetail);
      }
      break;
    }
    case 'Stop':
      setPhase(snap, 'awaitingReply', null);
      if (payload.last_assistant_message) {
        snap.lastQuestion = firstLine(payload.last_assistant_message);
      } else {
        out.readTranscript = true;
      }
      break;
    case 'SessionEnd':
      setPhase(snap, 'finished', null);
      break;
    default:
      break;
  }
  return out;
}

/** statusLine payload → model, context %, cost. */
function applyStatusLine(snap, obj) {
  if (!obj || typeof obj !== 'object') return;
  const cw = obj.context_window;
  if (cw && typeof cw.used_percentage === 'number') snap.contextPercent = Math.round(cw.used_percentage);
  if (obj.cost && typeof obj.cost.total_cost_usd === 'number') snap.costCents = Math.round(obj.cost.total_cost_usd * 100);
  if (obj.model && obj.model.display_name) snap.model = obj.model.display_name;
}

/** The last thing the assistant said, from the tail of a transcript .jsonl. */
function lastAssistantLine(jsonlTail) {
  const lines = String(jsonlTail).split('\n');
  for (let i = lines.length - 1; i >= 0; i--) {
    const line = lines[i].trim();
    if (!line.startsWith('{')) continue;
    let obj;
    try { obj = JSON.parse(line); } catch { continue; }
    if (obj.type !== 'assistant' || !obj.message) continue;
    const content = Array.isArray(obj.message.content) ? obj.message.content : [];
    for (let j = content.length - 1; j >= 0; j--) {
      if (content[j].type === 'text' && content[j].text && content[j].text.trim()) {
        return lastMeaningfulLine(content[j].text);
      }
    }
  }
  return null;
}

function firstLine(text) {
  const l = String(text).split(/\r?\n/).map((s) => s.trim()).find(Boolean);
  return l ? l.slice(0, 200) : null;
}

/** The line a turn ended on — usually its last sentence, which is what asks you something. */
function lastMeaningfulLine(text) {
  const lines = String(text).split(/\r?\n/).map((s) => s.replace(/^[#>*\-\s]+/, '').trim()).filter(Boolean);
  const l = lines[lines.length - 1];
  return l ? l.slice(0, 200) : null;
}

/**
 * Plain shell sessions and Codex/Qwen get no hook feed: output in the last
 * 3 s means working, otherwise idle. Same fallback as runClassifier's
 * output-recency rule.
 */
function applyOutputRecency(snap, now = Date.now()) {
  if (snap.tool === 'claude' || snap.state !== 'running') return false;
  const working = now - snap.lastOutputAt < 3000;
  const want = working ? 'thinking' : (snap.phase === 'thinking' ? 'awaitingReply' : snap.phase);
  if (want !== snap.phase) { setPhase(snap, want, null); return true; }
  return false;
}

/** Strip ANSI escapes from raw pty output. */
function stripAnsi(s) {
  // eslint-disable-next-line no-control-regex
  return String(s).replace(/\x1b\][^\x07\x1b]*(\x07|\x1b\\)/g, '').replace(/\x1b\[[0-9;?<>=]*[ -/]*[@-~]/g, '').replace(/\x1b[@-_]/g, '');
}

/**
 * Dialogs Claude draws before (or without) a hook firing — the folder-trust
 * prompt above all. Read off the tail of the screen, the pane reader's job on
 * the mac. Returns the question, or null.
 */
function readDialog(rawTail) {
  const text = stripAnsi(rawTail);
  const tail = text.slice(-3000);
  if (/Yes, I trust this folder/i.test(tail) && /Enter to confirm/i.test(tail)) return 'Trust this folder?';
  if (/Choose the text style/i.test(tail)) return 'Finish Claude setup (pick a theme)';
  if (/Select login method/i.test(tail)) return 'Sign in to Claude';
  const m = tail.match(/(Do you want to [^\n?]{0,120}\?)[\s\S]{0,600}(❯|>)\s*1\.\s*Yes/);
  if (m && /Esc to cancel/i.test(tail.slice(tail.lastIndexOf(m[1])))) return m[1].trim();
  return null;
}

module.exports = {
  newSnapshot, detectTool, setPhase, toolPhrase, applyHookEvent, applyStatusLine,
  lastAssistantLine, applyOutputRecency, stripAnsi, readDialog,
};
