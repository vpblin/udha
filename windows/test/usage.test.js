'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { parseStatusLimits, parseApiUsage, isLimitNotice, load, UsageStore } = require('../src/main/usage');
const { findTranscript } = require('../src/main/sessions');

test('statusLine rate_limits and API usage parse', () => {
  const s = parseStatusLimits({ five_hour: { used_percentage: 41.6, resets_at: 1789379400 }, seven_day: { used_percentage: 12 } });
  assert.equal(s.fiveHour.pct, 42);
  assert.equal(s.fiveHour.resetsAt, 1789379400000);
  assert.equal(s.sevenDay.pct, 12);
  assert.equal(parseStatusLimits({}), null);

  const a = parseApiUsage({
    five_hour: { utilization: 18.0, resets_at: '2026-09-18T10:30:00.672633+00:00' },
    seven_day: { utilization: 55 },
    limits: [{ kind: 'weekly_scoped', percent: 70, scope: { model: { display_name: 'Fable' } } }],
  });
  assert.equal(a.fiveHour.pct, 18);
  assert.equal(a.fiveHour.resetsAt, Date.parse('2026-09-18T10:30:00+00:00'));
  assert.equal(a.scoped.label, 'Fable');
  assert.equal(load(a), 70);
});

test('limit notices', () => {
  assert.ok(isLimitNotice('Claude usage limit reached. Your limit will reset at 3pm'));
  assert.ok(isLimitNotice('5-hour limit reached ∙ resets 3pm'));
  assert.ok(!isLimitNotice('> what is a rate limit?'));
});

test('choose picks the signed-in login with the most room', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'udha-usage-'));
  const store = { config: { claudeLogins: [] }, mutate(fn) { fn(this.config); } };
  const u = new UsageStore(store, dir, { defaultDir: path.join(dir, 'default-not-signed-in') });
  const a = u.add('Work'); const b = u.add('Personal');
  for (const l of [a, b]) fs.writeFileSync(path.join(l.configDir, '.credentials.json'), JSON.stringify({ claudeAiOauth: { accessToken: 'x' } }));
  u.record(a.configDir, { fiveHour: { pct: 80 }, sevenDay: { pct: 10 } });
  u.record(b.configDir, { fiveHour: { pct: 20 }, sevenDay: { pct: 30 } });
  assert.equal(u.choose(path.join(os.homedir(), '.claude')).name, 'Personal');
  u.markLimited(b.configDir);
  assert.equal(u.choose(path.join(os.homedir(), '.claude')).name, 'Work');
  assert.equal(u.choose(a.configDir), null);
});

test('findTranscript looks across login dirs', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'udha-tx-'));
  const login = path.join(dir, 'l1');
  fs.mkdirSync(path.join(login, 'projects', 'C--code-app'), { recursive: true });
  fs.writeFileSync(path.join(login, 'projects', 'C--code-app', 'abc.jsonl'), '{}');
  assert.equal(findTranscript('abc', [path.join(dir, 'nope'), login]), path.join(login, 'projects', 'C--code-app', 'abc.jsonl'));
  assert.equal(findTranscript('zzz', [login]), null);
});
