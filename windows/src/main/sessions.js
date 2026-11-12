// Sessions on Windows: one ConPTY process per session (no tmux). What makes a
// session survive a restart is the saved SessionConfig plus Claude's own
// transcript: on launch every saved session is started again, a Claude one
// with `--resume <id>` so the conversation picks up where it stopped.
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { EventEmitter } = require('events');
const pty = require('@lydell/node-pty');
const { Terminal: HeadlessTerminal } = require('@xterm/headless');
const status = require('./status');
const panes = require('./panes');
const { isLimitNotice } = require('./usage');

const BUFFER_MAX = 512 * 1024;   // raw output kept per session for re-drawing the terminal
const FEED_POLL_MS = 400;

class SessionManager extends EventEmitter {
  /**
   * @param {import('./config').ConfigStore} store
   * @param {{ statusDir: string, hookScript: string, settingsFile: string }} paths
   */
  constructor(store, paths) {
    super();
    this.store = store;
    this.paths = paths;
    this.snapshots = new Map();  // id → snapshot
    this.procs = new Map();      // id → IPty
    this.buffers = new Map();    // id → string
    this.feedOffsets = new Map();
    this.size = { cols: 120, rows: 32 };
    this._dirty = new Set();
    this._pendingData = new Map();
  }

  init() {
    fs.mkdirSync(this.paths.statusDir, { recursive: true });
    this.writeClaudeSettings();
    for (const cfg of this.store.config.sessions) this.snapshots.set(cfg.id, status.newSnapshot(cfg));
    this._poll = setInterval(() => this.tick(), FEED_POLL_MS);
    this._flush = setInterval(() => this.flushData(), 16);
    if (this.store.config.restoreOnLaunch) {
      for (const cfg of this.store.config.sessions) if (cfg.enabled) this.start(cfg.id);
    }
  }

  // MARK: - Claude sidecar

  /** The settings file handed to Claude with --settings: hooks + statusLine → hook.js. */
  writeClaudeSettings() {
    const node = findNode();
    const script = this.paths.hookScript.replace(/\\/g, '/');
    const cmd = (mode) => `"${node.replace(/\\/g, '/')}" "${script}" ${mode}`;
    const hook = [{ hooks: [{ type: 'command', command: cmd('event'), timeout: 10 }] }];
    const toolHook = [{ matcher: '*', hooks: [{ type: 'command', command: cmd('event'), timeout: 10 }] }];
    const settings = {
      hooks: {
        SessionStart: hook,
        UserPromptSubmit: hook,
        PreToolUse: toolHook,
        PostToolUse: toolHook,
        Notification: hook,
        Stop: hook,
        SubagentStop: hook,
        SessionEnd: hook,
      },
      statusLine: { type: 'command', command: cmd('statusline'), padding: 0 },
    };
    fs.writeFileSync(this.paths.settingsFile, JSON.stringify(settings, null, 2));
  }

  // MARK: - Lifecycle

  list() {
    return this.store.config.sessions
      .map((c) => {
        const s = this.snapshots.get(c.id);
        return s ? { ...publicSnapshot(s), notifyWhenDone: !!c.notifyWhenDone } : null;
      })
      .filter(Boolean);
  }

  create(cfg) {
    this.store.mutate((c) => c.sessions.push(cfg));
    this.snapshots.set(cfg.id, status.newSnapshot(cfg));
    this.start(cfg.id);
    this.emitChanged(cfg.id);
    return cfg.id;
  }

  start(id) {
    const cfg = this.store.session(id);
    const snap = this.snapshots.get(id);
    if (!cfg || !snap || this.procs.has(id)) return false;

    if (!fs.existsSync(cfg.directory)) {
      snap.state = 'exited';
      status.setPhase(snap, 'finished', `Folder not found: ${cfg.directory}`);
      this.emitChanged(id);
      return false;
    }

    const tool = status.detectTool(cfg.command);
    let args = [...(cfg.args || [])];
    let resumed = false;
    const env = { ...process.env, ...cfg.env, UDHA_SESSION_ID: id, UDHA_STATUS_DIR: this.paths.statusDir };
    delete env.ELECTRON_RUN_AS_NODE;
    if (tool === 'claude') {
      args = stripFlag(stripFlag(args, '--resume'), '--session-id');
      const sid = cfg.claudeSessionID || id;
      if (transcriptExists(sid, env.CLAUDE_CONFIG_DIR)) {
        args.push('--resume', sid);
        resumed = true;
      } else {
        // A fresh conversation under an id we chose, so it can be resumed later.
        args.push('--session-id', sid);
      }
      args.push('--settings', this.paths.settingsFile);
      snap.claudeSessionID = sid;
      // Start every launch with a clean feed so old events can't replay.
      for (const f of [`${id}.jsonl`, `${id}.status.json`]) {
        try { fs.rmSync(path.join(this.paths.statusDir, f), { force: true }); } catch { /* ignore */ }
      }
      this.feedOffsets.set(id, 0);
    }

    let proc;
    try {
      const { file, argv } = resolveLaunch(cfg.command, args, env);
      proc = pty.spawn(file, argv, {
        name: 'xterm-256color',
        cols: this.size.cols,
        rows: this.size.rows,
        cwd: cfg.directory,
        env,
        useConpty: true,
      });
    } catch (err) {
      snap.state = 'exited';
      status.setPhase(snap, 'finished', `Could not start: ${err.message}`);
      this.emitChanged(id);
      return false;
    }

    this.procs.set(id, proc);
    this.buffers.set(id, resumed ? '' : (this.buffers.get(id) || ''));
    snap.loginDir = cfg.env && cfg.env.CLAUDE_CONFIG_DIR ? cfg.env.CLAUDE_CONFIG_DIR : null;
    // Which branch the folder is on (a worktree session already knows).
    if (!cfg.worktree) {
      require('./git').currentBranch(cfg.directory).then((b) => {
        if (b !== snap.branch) { snap.branch = b; this.emitChanged(id); }
      });
    }
    // A headless copy of the screen — what `tmux capture-pane` gave the mac
    // pane reader — so on-screen dialogs can be read as they actually look.
    if (this.screens && this.screens.get(id)) this.screens.get(id).dispose();
    this.screens = this.screens || new Map();
    const screen = new HeadlessTerminal({ cols: this.size.cols, rows: this.size.rows, scrollback: 0, allowProposedApi: true });
    this.screens.set(id, screen);
    this.paneTrackers = this.paneTrackers || new Map();
    this.paneTrackers.set(id, { pending: null, count: 0 });
    snap.state = 'running';
    snap.exitCode = null;
    snap.startedAt = Date.now();
    snap.lastQuestion = null;
    status.setPhase(snap, 'starting', resumed ? 'Resuming conversation' : null);

    proc.onData((data) => {
      if (this.procs.get(id) !== proc) return;
      let buf = (this.buffers.get(id) || '') + data;
      if (buf.length > BUFFER_MAX) buf = buf.slice(buf.length - BUFFER_MAX);
      this.buffers.set(id, buf);
      screen.write(data);
      snap.lastOutputAt = Date.now();
      this._pendingData.set(id, (this._pendingData.get(id) || '') + data);
    });
    proc.onExit(({ exitCode }) => {
      if (this.procs.get(id) !== proc) return;
      this.procs.delete(id);
      this.readFeed(id);
      const s = this.snapshots.get(id);
      if (!s) return;
      s.exitCode = exitCode;
      s.state = s._stopping ? 'stopped' : 'exited';
      s._stopping = false;
      status.setPhase(s, s.state === 'stopped' ? 'idle' : 'finished', null);
      this.emitChanged(id);
    });
    this.emitChanged(id);
    return true;
  }

  stop(id) {
    const proc = this.procs.get(id);
    const snap = this.snapshots.get(id);
    if (!proc || !snap) return false;
    snap._stopping = true;
    try { proc.kill(); } catch { /* already gone */ }
    return true;
  }

  restart(id) {
    const proc = this.procs.get(id);
    if (!proc) return this.start(id);
    const snap = this.snapshots.get(id);
    snap._stopping = true;
    const done = proc.onExit(() => { done.dispose(); setTimeout(() => this.start(id), 150); });
    try { proc.kill(); } catch { /* ignore */ }
    return true;
  }

  remove(id) {
    this.stop(id);
    this.procs.delete(id);
    this.snapshots.delete(id);
    this.buffers.delete(id);
    if (this.screens && this.screens.get(id)) { this.screens.get(id).dispose(); this.screens.delete(id); }
    this.store.mutate((c) => {
      c.sessions = c.sessions.filter((s) => s.id !== id);
      if (c.selectedSessionID === id) c.selectedSessionID = null;
    });
    for (const f of [`${id}.jsonl`, `${id}.status.json`]) {
      try { fs.rmSync(path.join(this.paths.statusDir, f), { force: true }); } catch { /* ignore */ }
    }
    // Pasted images belonged to this session only.
    try { fs.rmSync(path.join(path.dirname(this.paths.statusDir), 'attachments', id), { recursive: true, force: true }); } catch { /* ignore */ }
    this.emit('removed', id);
  }

  rename(id, label) {
    label = String(label || '').trim();
    if (!label) return;
    this.store.mutate((c) => { const s = c.sessions.find((x) => x.id === id); if (s) s.label = label; });
    const snap = this.snapshots.get(id);
    if (snap) { snap.label = label; this.emitChanged(id); }
  }

  /** Change a Claude session's permission mode; a running one restarts and resumes its conversation. */
  setPermission(id, mode) {
    const { withPermission } = require('./config');
    const cfg = this.store.session(id);
    if (!cfg) return false;
    this.store.mutate(() => { cfg.args = withPermission(cfg.args, mode); });
    const snap = this.snapshots.get(id);
    if (snap) { snap.permission = mode; this.emitChanged(id); }
    if (this.procs.has(id)) this.restart(id);
    return true;
  }

  /**
   * Move a Claude session to another login (CLAUDE_CONFIG_DIR; null = the
   * default ~\.claude), keeping the conversation: its transcript is copied
   * into the new login's projects folder so `--resume <id>` finds it there.
   * `allDirs` are every login's config dir, to find where the transcript is.
   */
  moveToLogin(id, configDir, allDirs, { continueAfter = false } = {}) {
    const cfg = this.store.session(id);
    const snap = this.snapshots.get(id);
    if (!cfg || !snap || snap.tool !== 'claude') return false;
    const sid = cfg.claudeSessionID || id;
    const target = configDir || path.join(os.homedir(), '.claude');
    const source = findTranscript(sid, allDirs);
    if (source) {
      const dest = path.join(target, 'projects', path.basename(path.dirname(source)), `${sid}.jsonl`);
      if (path.resolve(dest).toLowerCase() !== path.resolve(source).toLowerCase()) {
        fs.mkdirSync(path.dirname(dest), { recursive: true });
        fs.copyFileSync(source, dest);
      }
    }
    this.store.mutate(() => {
      cfg.env = { ...(cfg.env || {}) };
      if (configDir) cfg.env.CLAUDE_CONFIG_DIR = configDir; else delete cfg.env.CLAUDE_CONFIG_DIR;
    });
    snap.loginDir = configDir || null;
    const running = this.procs.has(id);
    if (running) this.restart(id); else this.emitChanged(id);
    if (running && continueAfter && source) {
      setTimeout(() => this.sendPromptWhenReady(id, 'Continue where you left off.'), 1500);
    }
    return true;
  }

  /** Patch saved fields that the snapshot mirrors (hidden, folderID). */
  patch(id, fields) {
    const snap = this.snapshots.get(id);
    this.store.mutate((c) => {
      const s = c.sessions.find((x) => x.id === id);
      if (s) Object.assign(s, fields);
    });
    if (snap) { Object.assign(snap, fields); this.emitChanged(id); }
  }

  reorder(ids) {
    this.store.mutate((c) => {
      const byId = new Map(c.sessions.map((s) => [s.id, s]));
      const ordered = ids.map((i) => byId.get(i)).filter(Boolean);
      const rest = c.sessions.filter((s) => !ids.includes(s.id));
      c.sessions = [...ordered, ...rest];
    });
    this.emit('reordered');
  }

  write(id, data) {
    const proc = this.procs.get(id);
    if (proc) proc.write(data);
  }

  /** Type a message and submit it — the text and the Enter go separately so Claude doesn't read it as a paste. */
  send(id, text) {
    const proc = this.procs.get(id);
    if (!proc || !text) return false;
    proc.write(text);
    setTimeout(() => { if (this.procs.get(id) === proc) proc.write('\r'); }, 60);
    return true;
  }

  /**
   * Paste a first prompt once the session is ready for it (schedulePrompt on
   * the mac): wait for Claude's input box, and keep waiting while a dialog
   * such as folder trust is up — a paste into a dialog would answer it. After
   * the ceiling paste anyway: a late paste is recoverable, a dropped one isn't.
   */
  sendPromptWhenReady(id, prompt) {
    if (!prompt) return;
    const started = Date.now();
    let hardDeadline = started + 20000;
    const timer = setInterval(() => {
      const proc = this.procs.get(id);
      const snap = this.snapshots.get(id);
      if (!proc || !snap || snap.state !== 'running') { clearInterval(timer); return; }
      const screen = this.screenText(id);
      const dialog = status.readDialog(screen);
      if (dialog) { hardDeadline = Date.now() + 10 * 60 * 1000; return; }   // the user has to answer it first
      const inputBox = /\?\s*for shortcuts|accept edits|shift\s*\+?\s*tab|plan mode|bypass permissions|│\s*>\s|^\s*>\s*$/im.test(screen);
      const ready = snap.tool === 'claude' ? inputBox && Date.now() - snap.lastOutputAt > 400 : snap.phase !== 'starting';
      if (!ready && Date.now() < hardDeadline) return;
      clearInterval(timer);
      // Bracketed paste keeps a multi-line prompt as one message.
      proc.write(`\x1b[200~${prompt.replace(/\r?\n/g, '\r')}\x1b[201~`);
      setTimeout(() => { if (this.procs.get(id) === proc) proc.write('\r'); }, 300);
    }, 300);
  }

  resize(id, cols, rows) {
    if (!(cols > 10 && rows > 3)) return;
    this.size = { cols, rows };
    const proc = this.procs.get(id);
    if (proc) { try { proc.resize(cols, rows); } catch { /* exited */ } }
    const screen = this.screens && this.screens.get(id);
    if (screen) { try { screen.resize(cols, rows); } catch { /* ignore */ } }
  }

  /** The visible screen as plain text. */
  screenText(id) {
    const screen = this.screens && this.screens.get(id);
    if (!screen) return '';
    const b = screen.buffer.active;
    const lines = [];
    for (let i = 0; i < screen.rows; i++) {
      const line = b.getLine(b.viewportY + i);
      lines.push(line ? line.translateToString(true) : '');
    }
    return lines.join('\n');
  }

  buffer(id) { return this.buffers.get(id) || ''; }

  shutdown() {
    clearInterval(this._poll);
    clearInterval(this._flush);
    for (const [id, proc] of this.procs) {
      const snap = this.snapshots.get(id);
      if (snap) snap._stopping = true;
      try { proc.kill(); } catch { /* ignore */ }
    }
    this.store.saveNow();
  }

  // MARK: - Status feed

  tick() {
    for (const [id, snap] of this.snapshots) {
      if (snap.state !== 'running') continue;
      if (snap.tool === 'claude') this.readFeed(id);
      else if (this.readPane(id)) this.emitChanged(id);
    }
  }

  /** Codex, Qwen and plain commands: classify the visible screen (no hook feed). Returns true on change. */
  readPane(id) {
    const snap = this.snapshots.get(id);
    const tracker = this.paneTrackers && this.paneTrackers.get(id);
    if (!snap || !tracker) return false;
    const lines = this.screenText(id).split('\n');
    const raw = snap.tool === 'codex' ? panes.classifyCodexPane(lines) : panes.classifyGeneric(lines);
    // Output in the last 3 s with nothing else matched means it's producing.
    if ((raw.state === null || raw.state === 'idle') && Date.now() - snap.lastOutputAt < 3000 && snap.phase !== 'awaitingApproval') {
      raw.state = 'working';
    }
    if (raw.state === null) return false;
    const result = panes.stable(tracker, raw);
    if (!result) return false;
    const before = `${snap.phase}|${snap.phaseDetail}|${snap.lastQuestion}`;
    switch (result.state) {
      case 'needsInput':
        status.setPhase(snap, 'awaitingApproval', result.prompt || 'Waiting for input');
        if (result.question) snap.lastQuestion = result.question;
        break;
      case 'working':
        status.setPhase(snap, result.activity ? 'usingTool' : 'thinking', result.activity || null);
        break;
      case 'error':
        status.setPhase(snap, 'idle', result.activity);
        break;
      case 'idle': {
        // Something that was busy and stopped has finished its turn ("Ready");
        // a fresh launch that settles is just idle.
        const wasBusy = ['thinking', 'usingTool', 'awaitingApproval'].includes(snap.phase);
        const next = snap.phase === 'starting' ? 'idle' : (wasBusy || snap.phase === 'awaitingReply') ? 'awaitingReply' : 'idle';
        status.setPhase(snap, next, null);
        if (result.question) snap.lastQuestion = result.question;
        break;
      }
      default: break;
    }
    return before !== `${snap.phase}|${snap.phaseDetail}|${snap.lastQuestion}`;
  }

  readFeed(id) {
    const snap = this.snapshots.get(id);
    if (!snap) return;
    let changed = false;

    const feed = path.join(this.paths.statusDir, `${id}.jsonl`);
    try {
      const st = fs.statSync(feed);
      let offset = this.feedOffsets.get(id) || 0;
      if (st.size < offset) offset = 0;
      if (st.size > offset) {
        const fd = fs.openSync(feed, 'r');
        const buf = Buffer.alloc(st.size - offset);
        fs.readSync(fd, buf, 0, buf.length, offset);
        fs.closeSync(fd);
        const text = buf.toString('utf8');
        const lastNl = text.lastIndexOf('\n');
        if (lastNl >= 0) {
          this.feedOffsets.set(id, offset + Buffer.byteLength(text.slice(0, lastNl + 1)));
          for (const line of text.slice(0, lastNl).split('\n')) {
            let env;
            try { env = JSON.parse(line); } catch { continue; }
            const out = status.applyHookEvent(snap, env.payload);
            changed = true;
            if (out.claudeSessionID) {
              this.store.mutate((c) => { const s = c.sessions.find((x) => x.id === id); if (s) s.claudeSessionID = out.claudeSessionID; });
            }
            if (out.transcriptPath) snap._transcript = out.transcriptPath;
            if (out.readTranscript && snap._transcript) snap.lastQuestion = readLastAssistantLine(snap._transcript);
          }
        }
      }
    } catch { /* no feed yet */ }

    const statusFile = path.join(this.paths.statusDir, `${id}.status.json`);
    try {
      const st = fs.statSync(statusFile);
      if (st.mtimeMs !== snap._statusMtime) {
        snap._statusMtime = st.mtimeMs;
        const obj = JSON.parse(fs.readFileSync(statusFile, 'utf8'));
        status.applyStatusLine(snap, obj);
        if (obj.rate_limits) this.emit('rate-limits', snap.loginDir, obj.rate_limits);
        changed = true;
      }
    } catch { /* none yet */ }

    // On-screen dialogs (folder trust, "Do you want to …?") win over the feed;
    // when one closes, fall back to whatever the feed says next.
    if (snap.state === 'running') {
      const screenNow = this.screenText(id);
      // Out of usage on this login: say so once, and let main decide whether to move it.
      if (isLimitNotice(screenNow) && !(snap._limitAt > Date.now() - 10 * 60000)) {
        snap._limitAt = Date.now();
        this.emit('limit', id, snap.loginDir);
      }
      const dialog = status.readDialog(screenNow);
      if (dialog && (snap.phase !== 'awaitingApproval' || snap.phaseDetail !== dialog)) {
        status.setPhase(snap, 'awaitingApproval', dialog);
        snap._dialog = dialog;
        changed = true;
      } else if (!dialog && snap._dialog) {
        snap._dialog = null;
        if (snap.phase === 'awaitingApproval') status.setPhase(snap, 'idle', null);
        changed = true;
      }
    }

    // A Claude session that has drawn its UI but fired no hook yet is simply idle.
    if (snap.phase === 'starting' && snap.lastOutputAt && Date.now() - snap.startedAt > 4000) {
      status.setPhase(snap, 'idle', null);
      changed = true;
    }
    if (changed) this.emitChanged(id);
  }

  emitChanged(id) {
    const snap = this.snapshots.get(id);
    if (!snap) return;
    const cfg = this.store.session(id);
    const pub = publicSnapshot(snap);
    pub.notifyWhenDone = !!(cfg && cfg.notifyWhenDone);
    this.emit('changed', pub);
  }

  flushData() {
    if (!this._pendingData.size) return;
    for (const [id, data] of this._pendingData) this.emit('data', id, data);
    this._pendingData.clear();
  }
}

function publicSnapshot(s) {
  const out = {};
  for (const [k, v] of Object.entries(s)) if (!k.startsWith('_')) out[k] = v;
  return out;
}

function stripFlag(args, flag) {
  const out = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === flag) { i++; continue; }
    out.push(args[i]);
  }
  return out;
}

/** Claude keeps a conversation at <config>/projects/<slug>/<id>.jsonl. */
function transcriptExists(sessionID, configDir) {
  const root = path.join(configDir || path.join(os.homedir(), '.claude'), 'projects');
  let dirs;
  try { dirs = fs.readdirSync(root); } catch { return false; }
  return dirs.some((d) => fs.existsSync(path.join(root, d, `${sessionID}.jsonl`)));
}

/** Where a conversation's transcript lives, across several config dirs. */
function findTranscript(sessionID, configDirs) {
  for (const dir of configDirs) {
    const root = path.join(dir || path.join(os.homedir(), '.claude'), 'projects');
    let subs;
    try { subs = fs.readdirSync(root); } catch { continue; }
    for (const d of subs) {
      const p = path.join(root, d, `${sessionID}.jsonl`);
      if (fs.existsSync(p)) return p;
    }
  }
  return null;
}

function readLastAssistantLine(file) {
  try {
    const st = fs.statSync(file);
    const len = Math.min(st.size, 256 * 1024);
    const fd = fs.openSync(file, 'r');
    const buf = Buffer.alloc(len);
    fs.readSync(fd, buf, 0, len, st.size - len);
    fs.closeSync(fd);
    return status.lastAssistantLine(buf.toString('utf8'));
  } catch { return null; }
}

/** Find a command the way cmd.exe would (PATH × PATHEXT); .cmd/.bat shims go through cmd /c. */
function resolveLaunch(command, args, env) {
  const exts = (env.PATHEXT || '.COM;.EXE;.BAT;.CMD').split(';').filter(Boolean);
  const pathVar = env.Path || env.PATH || '';
  let found = null;
  const candidates = path.isAbsolute(command) || command.includes('\\') || command.includes('/')
    ? [command]
    : pathVar.split(';').filter(Boolean).map((d) => path.join(d, command));
  outer: for (const base of candidates) {
    if (path.extname(base) && fs.existsSync(base) && fs.statSync(base).isFile()) { found = base; break; }
    for (const ext of exts) {
      if (fs.existsSync(base + ext)) { found = base + ext; break outer; }
      if (fs.existsSync(base + ext.toLowerCase())) { found = base + ext.toLowerCase(); break outer; }
    }
  }
  if (!found) throw new Error(`'${command}' was not found on PATH`);
  if (/\.(cmd|bat)$/i.test(found)) {
    const line = [quoteArg(found), ...args.map(quoteArg)].join(' ');
    return { file: env.ComSpec || 'C:\\Windows\\System32\\cmd.exe', argv: `/d /s /c "${line}"` };
  }
  if (/\.ps1$/i.test(found)) {
    return { file: 'powershell.exe', argv: ['-NoLogo', '-ExecutionPolicy', 'Bypass', '-File', found, ...args] };
  }
  return { file: found, argv: args };
}

function quoteArg(a) {
  a = String(a);
  if (a && !/[\s"&|<>^()%!]/.test(a)) return a;
  return `"${a.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/, '$1$1')}"`;
}

function findNode() {
  const pathVar = process.env.Path || process.env.PATH || '';
  for (const d of pathVar.split(';').filter(Boolean)) {
    const p = path.join(d, 'node.exe');
    if (fs.existsSync(p)) return p;
  }
  return 'node';
}

module.exports = { SessionManager, resolveLaunch, quoteArg, stripFlag, transcriptExists, findTranscript };
