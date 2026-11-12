'use strict';
const test = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const status = require('../src/main/status');
const { ConfigStore, newSessionConfig } = require('../src/main/config');
const { presentation } = require('../src/renderer/presentation');

function running(cfg) {
  const s = status.newSnapshot(cfg);
  s.state = 'running';
  return s;
}

test('detectTool reads the binary name', () => {
  assert.equal(status.detectTool('claude'), 'claude');
  assert.equal(status.detectTool('C:\\x\\claude.cmd'), 'claude');
  assert.equal(status.detectTool('codex'), 'codex');
  assert.equal(status.detectTool('powershell'), null);
});

test('hook events drive the phase like the mac sidecar', () => {
  const cfg = newSessionConfig({ label: 'a', directory: 'C:\\' });
  const s = running(cfg);
  status.applyHookEvent(s, { hook_event_name: 'UserPromptSubmit', session_id: cfg.id });
  assert.equal(s.phase, 'thinking');
  status.applyHookEvent(s, { hook_event_name: 'PreToolUse', tool_name: 'Edit', tool_input: { file_path: 'C:\\p\\main.js' } });
  assert.equal(s.phase, 'usingTool');
  assert.equal(s.phaseDetail, 'Editing main.js');
  assert.equal(presentation(s).label, 'Editing main.js');
  status.applyHookEvent(s, { hook_event_name: 'Notification', message: 'Claude needs your permission to use Bash' });
  assert.equal(s.phase, 'awaitingApproval');
  assert.equal(presentation(s).label, 'Needs approval');
  status.applyHookEvent(s, { hook_event_name: 'PostToolUse', tool_name: 'Bash' });
  assert.equal(s.phase, 'thinking');
  const out = status.applyHookEvent(s, { hook_event_name: 'Stop', last_assistant_message: 'Done.\nShall I commit?' });
  assert.equal(s.phase, 'awaitingReply');
  assert.equal(s.lastQuestion, 'Done.');
  assert.equal(presentation(s).label, 'Ready');
  assert.equal(out.claudeSessionID, undefined);
});

test('a new Claude session id (after /clear) is reported for saving', () => {
  const cfg = newSessionConfig({ label: 'a', directory: 'C:\\' });
  const s = running(cfg);
  const out = status.applyHookEvent(s, { hook_event_name: 'SessionStart', session_id: 'new-id' });
  assert.equal(out.claudeSessionID, 'new-id');
  assert.equal(s.claudeSessionID, 'new-id');
});

test('Ready turns Stale after staleAfter', () => {
  const s = running(newSessionConfig({ label: 'a', directory: 'C:\\' }));
  status.setPhase(s, 'awaitingReply', null);
  s.phaseEnteredAt = Date.now() - 3600 * 1000;
  assert.equal(presentation(s, 1800).label, 'Stale');
});

test('statusLine gives model, context and cost', () => {
  const s = running(newSessionConfig({ label: 'a', directory: 'C:\\' }));
  status.applyStatusLine(s, { model: { display_name: 'Opus 5.5' }, context_window: { used_percentage: 41.6 }, cost: { total_cost_usd: 1.234 } });
  assert.equal(s.model, 'Opus 5.5');
  assert.equal(s.contextPercent, 42);
  assert.equal(s.costCents, 123);
});

test('lastAssistantLine reads the transcript tail', () => {
  const jsonl = [
    JSON.stringify({ type: 'user', message: { content: 'hi' } }),
    JSON.stringify({ type: 'assistant', message: { content: [{ type: 'text', text: 'Fixed it.\n\nWant me to run the tests?' }] } }),
  ].join('\n');
  assert.equal(status.lastAssistantLine(jsonl), 'Want me to run the tests?');
});

test('readDialog spots on-screen prompts', () => {
  assert.equal(status.readDialog('Quick safety check\n> No, exit\n  Yes, I trust this folder\n\nEnter to confirm · Esc to cancel'), 'Trust this folder?');
  assert.equal(status.readDialog('Bash command\n rm -rf build\nDo you want to proceed?\n❯ 1. Yes\n  2. No\nEsc to cancel'), 'Do you want to proceed?');
  assert.equal(status.readDialog('> \n? for shortcuts'), null);
});

test('config saves and reloads sessions, tolerating junk', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'udha-cfg-'));
  const a = new ConfigStore(dir);
  a.load();
  const cfg = newSessionConfig({ label: 'proj', directory: dir });
  a.mutate((c) => c.sessions.push(cfg));
  a.saveNow();
  const b = new ConfigStore(dir);
  b.load();
  assert.equal(b.config.sessions.length, 1);
  assert.equal(b.config.sessions[0].claudeSessionID, cfg.id);
  assert.deepEqual(b.config.sessions[0].args, ['--permission-mode', 'acceptEdits']);
  fs.writeFileSync(path.join(dir, 'config.json'), '{not json');
  const c = new ConfigStore(dir);
  c.load();
  assert.equal(c.config.sessions.length, 0);
  assert.ok(fs.readdirSync(dir).some((f) => f.startsWith('config.json.broken-')));
});
