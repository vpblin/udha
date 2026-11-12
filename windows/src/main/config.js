// The saved state: %APPDATA%\Udha\config.json. Loaded tolerantly like the mac
// ConfigStore — merged onto defaults, and a broken file is backed up rather
// than thrown away. Writes are atomic (tmp + rename) and debounced.
'use strict';

const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const DEFAULTS = {
  version: 1,
  sessions: [],
  sessionFolders: [],
  staleAfterSeconds: 1800,
  restoreOnLaunch: true,
  appearance: { mode: 'system', accent: 'blue' },
  selectedSessionID: null,
  terminal: { fontSize: 13 },
  window: null,
};

/** Permission modes, as ClaudePermissionMode in the mac app. */
const PERMISSION_ARGS = {
  default: [],
  acceptEdits: ['--permission-mode', 'acceptEdits'],
  plan: ['--permission-mode', 'plan'],
  bypass: ['--dangerously-skip-permissions'],
};

/** Replace whatever mode the args pin with `mode`, leaving every other flag alone. */
function withPermission(args = [], mode) {
  const out = [];
  for (let i = 0; i < args.length; i++) {
    if (args[i] === '--permission-mode') { i++; continue; }
    if (args[i] === '--dangerously-skip-permissions') continue;
    out.push(args[i]);
  }
  return [...(PERMISSION_ARGS[mode] || []), ...out];
}

function newSessionConfig({ label, directory, command = 'claude', args, permission = 'acceptEdits', env = {} }) {
  const id = crypto.randomUUID();
  const isClaude = /^claude(\.cmd|\.exe)?$/i.test(path.basename(command));
  return {
    id,
    label,
    directory,
    command,
    args: args ?? (isClaude ? [...(PERMISSION_ARGS[permission] || [])] : []),
    env,
    priority: 'normal',
    enabled: true,
    hidden: false,
    // Claude's own conversation id. Starts equal to ours (passed as
    // --session-id) and follows /clear via the SessionStart hook.
    claudeSessionID: isClaude ? id : null,
    createdAt: new Date().toISOString(),
  };
}

class ConfigStore {
  constructor(dir) {
    this.dir = dir;
    this.file = path.join(dir, 'config.json');
    this.config = structuredClone(DEFAULTS);
    this._timer = null;
  }

  load() {
    fs.mkdirSync(this.dir, { recursive: true });
    if (!fs.existsSync(this.file)) return this.config;
    try {
      const disk = JSON.parse(fs.readFileSync(this.file, 'utf8'));
      this.config = merge(structuredClone(DEFAULTS), disk);
      this.config.sessions = (Array.isArray(disk.sessions) ? disk.sessions : [])
        .filter((s) => s && typeof s.id === 'string' && typeof s.label === 'string')
        .map((s) => ({ args: [], env: {}, command: 'claude', enabled: true, hidden: false, priority: 'normal', ...s }));
    } catch (err) {
      const backup = `${this.file}.broken-${Date.now()}`;
      try { fs.copyFileSync(this.file, backup); } catch { /* ignore */ }
      console.error(`[config] unreadable, backed up to ${backup}:`, err.message);
    }
    return this.config;
  }

  mutate(fn) {
    fn(this.config);
    this.scheduleSave();
  }

  scheduleSave() {
    clearTimeout(this._timer);
    this._timer = setTimeout(() => this.saveNow(), 150);
  }

  saveNow() {
    clearTimeout(this._timer);
    this._timer = null;
    const tmp = `${this.file}.tmp`;
    fs.mkdirSync(this.dir, { recursive: true });
    fs.writeFileSync(tmp, JSON.stringify(this.config, null, 2));
    fs.renameSync(tmp, this.file);
  }

  session(id) {
    return this.config.sessions.find((s) => s.id === id);
  }
}

function merge(base, over) {
  if (!over || typeof over !== 'object' || Array.isArray(over)) return base;
  for (const [k, v] of Object.entries(over)) {
    if (v && typeof v === 'object' && !Array.isArray(v) && base[k] && typeof base[k] === 'object' && !Array.isArray(base[k])) {
      base[k] = merge(base[k], v);
    } else {
      base[k] = v;
    }
  }
  return base;
}

module.exports = { ConfigStore, newSessionConfig, PERMISSION_ARGS, DEFAULTS, withPermission };
