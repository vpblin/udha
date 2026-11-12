// Claude logins and their usage (ClaudeAccountPool.swift). A login is a
// CLAUDE_CONFIG_DIR: the default ~\.claude plus any you add. Readings come
// from Claude's own statusLine `rate_limits` (documented) and, to fill gaps,
// the usage endpoint with the token Claude left in .credentials.json — read
// only: Udha never refreshes a token, since rotating it behind a running
// Claude would sign that session out.
'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const https = require('https');

const DEFAULT_DIR = path.join(os.homedir(), '.claude');

function norm(dir) { return path.resolve(dir || DEFAULT_DIR).toLowerCase(); }

function parseStatusLimits(obj) {
  if (!obj || typeof obj !== 'object') return null;
  const w = (k) => {
    const x = obj[k];
    if (!x || typeof x.used_percentage !== 'number') return null;
    return { pct: Math.round(x.used_percentage), resetsAt: typeof x.resets_at === 'number' ? x.resets_at * 1000 : null };
  };
  const five = w('five_hour'); const seven = w('seven_day');
  return five || seven ? { fiveHour: five, sevenDay: seven, source: 'session' } : null;
}

function parseApiUsage(obj) {
  if (!obj || typeof obj !== 'object') return null;
  const iso = (s) => { const t = Date.parse(String(s || '').replace(/\.\d+/, '')); return Number.isFinite(t) ? t : null; };
  const w = (k) => {
    const x = obj[k];
    if (!x || typeof x.utilization !== 'number') return null;
    return { pct: Math.round(x.utilization), resetsAt: iso(x.resets_at) };
  };
  let scoped = null;
  for (const e of Array.isArray(obj.limits) ? obj.limits : []) {
    if (e && e.kind === 'weekly_scoped' && typeof e.percent === 'number') {
      scoped = { pct: Math.round(e.percent), resetsAt: iso(e.resets_at), label: e.scope && e.scope.model && e.scope.model.display_name };
      break;
    }
  }
  const five = w('five_hour'); const seven = w('seven_day');
  return five || seven || scoped ? { fiveHour: five, sevenDay: seven, scoped, source: 'api' } : null;
}

/** The fuller of the two windows — what "headroom" is measured against. */
function load(u) {
  if (!u) return 0;
  return Math.max(u.fiveHour ? u.fiveHour.pct : 0, u.sevenDay ? u.sevenDay.pct : 0, u.scoped ? u.scoped.pct : 0);
}

/** Text Claude prints when a login is out of usage. */
function isLimitNotice(screen) {
  return /(usage limit reached|limit reached\s*[∙·•|-]\s*resets|you've hit your (usage |session |weekly )?limit|out of extra usage)/i.test(screen);
}

class UsageStore {
  constructor(store, dataDir, { defaultDir = DEFAULT_DIR } = {}) {
    this.store = store;
    this.defaultDir = defaultDir;
    this.loginsDir = path.join(dataDir, 'logins');
    this.readings = new Map();     // norm(dir) → usage
    this.limitedUntil = new Map(); // norm(dir) → ms
  }

  logins() {
    const extra = (this.store.config.claudeLogins || []).map((l) => ({ ...l, isDefault: false }));
    return [{ id: 'default', name: 'Default', configDir: this.defaultDir, isDefault: true }, ...extra].map((l) => {
      const key = norm(l.configDir);
      const usage = this.readings.get(key) || null;
      const until = this.limitedUntil.get(key) || 0;
      return { ...l, email: this.email(l), signedIn: !!this.credentials(l.configDir), usage, limited: until > Date.now() || load(usage) >= 100, limitedUntil: until > Date.now() ? until : null };
    });
  }

  find(dir) { return this.logins().find((l) => norm(l.configDir) === norm(dir)) || null; }

  add(name) {
    const clean = String(name || '').trim() || 'Login';
    const slug = clean.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '') || 'login';
    let dir = path.join(this.loginsDir, slug);
    for (let n = 2; fs.existsSync(dir); n++) dir = path.join(this.loginsDir, `${slug}-${n}`);
    fs.mkdirSync(dir, { recursive: true });
    const login = { id: path.basename(dir), name: clean, configDir: dir };
    this.store.mutate((c) => { c.claudeLogins = [...(c.claudeLogins || []), login]; });
    return login;
  }

  remove(id) {
    this.store.mutate((c) => { c.claudeLogins = (c.claudeLogins || []).filter((l) => l.id !== id); });
  }

  /** The signed-in email: <dir>\.claude.json, or ~\.claude.json for the default login. */
  email(login) {
    const files = login.isDefault || norm(login.configDir) === norm(DEFAULT_DIR)
      ? [path.join(os.homedir(), '.claude.json'), path.join(DEFAULT_DIR, '.claude.json')]
      : [path.join(login.configDir, '.claude.json')];
    for (const f of files) {
      try {
        const obj = JSON.parse(fs.readFileSync(f, 'utf8'));
        if (obj.oauthAccount && obj.oauthAccount.emailAddress) return obj.oauthAccount.emailAddress;
      } catch { /* none */ }
    }
    return null;
  }

  credentials(configDir) {
    try {
      const obj = JSON.parse(fs.readFileSync(path.join(configDir, '.credentials.json'), 'utf8'));
      return obj.claudeAiOauth || null;
    } catch { return null; }
  }

  record(configDir, usage) {
    if (!usage) return;
    const key = norm(configDir);
    const prev = this.readings.get(key);
    // A session reading has no per-model cap; keep the last one the API gave.
    this.readings.set(key, { ...usage, scoped: usage.scoped || (prev && prev.scoped) || null, observedAt: Date.now() });
  }

  markLimited(configDir, minutes = 60) {
    this.limitedUntil.set(norm(configDir), Date.now() + minutes * 60000);
  }

  /** Probe the usage endpoint for one login. Resolves to the reading, or { error }. */
  probe(login) {
    const oauth = this.credentials(login.configDir);
    if (!oauth || !oauth.accessToken) return Promise.resolve({ error: 'Not signed in' });
    if (oauth.expiresAt && oauth.expiresAt < Date.now() + 60000) {
      return Promise.resolve({ error: 'Token expired — it refreshes the next time a session runs on this login' });
    }
    return new Promise((resolve) => {
      const req = https.request('https://api.anthropic.com/api/oauth/usage', {
        method: 'GET',
        timeout: 15000,
        headers: { Authorization: `Bearer ${oauth.accessToken}`, 'anthropic-beta': 'oauth-2025-04-20', 'User-Agent': 'udha-windows' },
      }, (res) => {
        let body = '';
        res.on('data', (c) => { body += c; });
        res.on('end', () => {
          if (res.statusCode < 200 || res.statusCode >= 300) return resolve({ error: `Usage endpoint answered ${res.statusCode}` });
          try {
            const u = parseApiUsage(JSON.parse(body));
            if (u) this.record(login.configDir, u);
            resolve(u || { error: 'No reading' });
          } catch { resolve({ error: 'Unreadable answer' }); }
        });
      });
      req.on('timeout', () => { req.destroy(); resolve({ error: 'Timed out' }); });
      req.on('error', (e) => resolve({ error: e.message }));
      req.end();
    });
  }

  /** The signed-in login with the most headroom, other than `avoid`. */
  choose(avoid) {
    return this.logins()
      .filter((l) => l.signedIn && !l.limited && norm(l.configDir) !== norm(avoid))
      .sort((a, b) => load(a.usage) - load(b.usage))[0] || null;
  }
}

module.exports = { UsageStore, parseStatusLimits, parseApiUsage, isLimitNotice, load, norm, DEFAULT_DIR };
